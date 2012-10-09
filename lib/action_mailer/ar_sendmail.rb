require 'net/smtp'
require 'smtp_tls'
require 'rubygems'

class Object # :nodoc:
  unless respond_to? :path2class then
    def self.path2class(path)
      path.split(/::/).inject self do |k,n| k.const_get n end
    end
  end
end

##
# Hack in RSET

module Net # :nodoc:
class SMTP # :nodoc:

  unless instance_methods.include? 'reset' then
    ##
    # Resets the SMTP connection.

    def reset
      getok 'RSET'
    end
  end

end
end

module ActionMailer; end # :nodoc:

##
# ActionMailer::ARSendmail delivers email from the email table to the
# SMTP server configured in your application's config/environment.rb.
# ar_sendmail does not work with sendmail delivery.
#
# ar_mailer can deliver to SMTP with TLS using smtp_tls.rb borrowed from Kyle
# Maxwell's action_mailer_optional_tls plugin.  Simply set the :tls option in
# ActionMailer::Base's smtp_settings to true to enable TLS.
#
# See ar_sendmail -h for the full list of supported options.
#
# The interesting options are:
# * --daemon
# * --mailq
# * --create-migration
# * --create-model
# * --table-name

class ActionMailer::ARSendmail

  ##
  # The version of ActionMailer::ARSendmail you are running.

  VERSION = '1.4.4'

  ##
  # Maximum number of times authentication will be consecutively retried

  MAX_AUTH_FAILURES = 2

  ##
  # Email delivery attempts per run

  attr_accessor :batch_size

  ##
  # Seconds to delay between runs

  attr_accessor :delay

  ##
  # Maximum age of emails in seconds before they are removed from the queue.

  attr_accessor :max_age

  ##
  # Be verbose

  attr_accessor :verbose
 
  ##
  # ActiveRecord class that holds emails

  attr_reader :email_table_name

  ##
  # True if only one delivery attempt will be made per call to run

  attr_reader :once

  ##
  # Times authentication has failed

  attr_accessor :failed_auth_count

  @@pid_file = nil

  def self.remove_pid_file
    if @@pid_file
      require 'shell'
      sh = Shell.new
      sh.rm @@pid_file
    end
  end

  ##
  # Creates a new migration using +table_name+ and prints it on stdout.

  def self.create_migration(table_name)
    require 'active_support'
    puts <<-EOF
class Add#{table_name.classify} < ActiveRecord::Migration
  def self.up
    create_table :#{table_name.tableize} do |t|
      t.column :from, :string
      t.column :to, :string
      t.column :last_send_attempt, :integer, :default => 0
      t.column :mail, :text
      t.column :created_on, :datetime
    end
  end

  def self.down
    drop_table :#{table_name.tableize}
  end
end
    EOF
  end

  ##
  # Creates a new model using +table_name+ and prints it on stdout.

  def self.create_model(table_name)
    require 'active_support'
    puts <<-EOF
class #{table_name.classify} < ActiveRecord::Base
end
    EOF
  end

  ##
  # Prints a list of unsent emails and the last delivery attempt, if any.
  #
  # If ActiveRecord::Timestamp is not being used the arrival time will not be
  # known.  See http://api.rubyonrails.org/classes/ActiveRecord/Timestamp.html
  # to learn how to enable ActiveRecord::Timestamp.

  def self.mailq(table_name)
    klass = table_name.split('::').inject(Object) { |k,n| k.const_get n }
    emails = klass.find :all

    if emails.empty? then
      puts "Mail queue is empty"
      return
    end

    total_size = 0

    puts "-Queue ID- --Size-- ----Arrival Time---- -Sender/Recipient-------"
    emails.each do |email|
      size = email.mail.length
      total_size += size

      create_timestamp = email.created_on rescue
                         email.created_at rescue
                         Time.at(email.created_date) rescue # for Robot Co-op
                         nil

      created = if create_timestamp.nil? then
                  '             Unknown'
                else
                  create_timestamp.strftime '%a %b %d %H:%M:%S'
                end

      puts "%10d %8d %s  %s" % [email.id, size, created, email.from]
      if email.last_send_attempt > 0 then
        puts "Last send attempt: #{Time.at email.last_send_attempt}"
      end
      puts "                                         #{email.to}"
      puts
    end

    puts "-- #{total_size/1024} Kbytes in #{emails.length} Requests."
  end

  ##
  # Processes +args+ and runs as appropriate

  def self.run(options)
    if options.include? :migrate then
      create_migration options[:tablename]
      exit
    elsif options.include? :model then
      create_model options[:tablename]
      exit
    elsif options.include? :mailq then
      mailq options[:tablename]
      exit
    end

    if options[:daemon] then
      require 'webrick/server'
      @@pid_file = File.expand_path(options[:pidfile], options[:chdir])
      if File.exists? @@pid_file
        # check to see if process is actually running
        pid = ''
        File.open(@@pid_file, 'r') {|f| pid = f.read.chomp }
        if system("ps -p #{pid} | grep #{pid}") # returns true if process is running, o.w. false
          $stderr.puts "Warning: The pid file #{@@pid_file} exists and ar_sendmail is running. Shutting down."
          exit
        else
          # not running, so remove existing pid file and continue
          self.remove_pid_file
          $stderr.puts "ar_sendmail is not running. Removing existing pid file and starting up..."
        end
      end
      WEBrick::Daemon.start
      File.open(@@pid_file, 'w') {|f| f.write("#{Process.pid}\n")}
    end

    new(options).run

  rescue SystemExit
    raise
  rescue SignalException
    exit
  rescue Exception => e
    $stderr.puts "Unhandled exception #{e.message}(#{e.class}):"
    $stderr.puts "\t#{e.backtrace.join "\n\t"}"
    exit 1
  end

  ##
  # Creates a new ARSendmail.
  #
  # Valid options are:
  # <tt>:BatchSize</tt>:: Maximum number of emails to send per delay
  # <tt>:Delay</tt>:: Delay between deliver attempts
  # <tt>:TableName</tt>:: Table name that stores the emails
  # <tt>:Once</tt>:: Only attempt to deliver emails once when run is called
  # <tt>:Verbose</tt>:: Be verbose.

  def initialize(options = {})
    options[:delay] ||= 60
    options[:tablename] ||= 'Email'
    options[:maxage] ||= 86400 * 7

    @batch_size = options[:batchsize]
    @delay = options[:delay]
    @email_table_name = options[:tablename]
    @once = options[:once]
    @verbose = options[:verbose]
    @max_age = options[:maxage]

    @failed_auth_count = 0
  end

  ##
  # Removes emails that have lived in the queue for too long.  If max_age is
  # set to 0, no emails will be removed.

  def cleanup
    return if @max_age == 0
    timeout = Time.now - @max_age
    conditions = ['last_send_attempt > 0 and created_on < ?', timeout]
    mail = email_class.destroy_all conditions

    log "expired #{mail.length} emails from the queue"
  end

  ##
  # Delivers +emails+ to ActionMailer's SMTP server and destroys them.

  def deliver(emails)
    user = smtp_settings[:user] || smtp_settings[:user_name]
    Net::SMTP.start smtp_settings[:address], smtp_settings[:port],
                    smtp_settings[:domain], user,
                    smtp_settings[:password],
                    smtp_settings[:authentication] do |smtp|
      @failed_auth_count = 0
      until emails.empty? do
        email = emails.shift
        begin
          res = smtp.send_message email.mail, email.from, email.to
          email.destroy
          log "sent email %011d from %s to %s: %p" %
                [email.id, email.from, email.to, res]
        rescue Net::SMTPFatalError => e
          log "5xx error sending email %d, removing from queue: %p(%s):\n\t%s" %
                [email.id, e.message, e.class, e.backtrace.join("\n\t")]
          email.destroy
          smtp.reset
        rescue Net::SMTPServerBusy => e
          log "server too busy, sleeping #{@delay} seconds"
          sleep delay
          return
        rescue Net::SMTPUnknownError, Net::SMTPSyntaxError, TimeoutError => e
          email.last_send_attempt = Time.now.to_i
          email.save rescue nil
          log "error sending email %d: %p(%s):\n\t%s" %
                [email.id, e.message, e.class, e.backtrace.join("\n\t")]
          smtp.reset
        end
      end
    end
  rescue Net::SMTPAuthenticationError => e
    @failed_auth_count += 1
    if @failed_auth_count >= MAX_AUTH_FAILURES then
      log "authentication error, giving up: #{e.message}"
      raise e
    else
      log "authentication error, retrying: #{e.message}"
    end
    sleep delay
  rescue Net::SMTPServerBusy, SystemCallError, OpenSSL::SSL::SSLError
    # ignore SMTPServerBusy/EPIPE/ECONNRESET from Net::SMTP.start's ensure
  end

  ##
  # Prepares ar_sendmail for exiting

  def do_exit
    log "caught signal, shutting down"
    self.class.remove_pid_file
    exit
  end

  def email_class
    Object.path2class @email_table_name
  end

  ##
  # Returns emails in email_class that haven't had a delivery attempt in the
  # last 300 seconds.

  def find_emails
    options = { :conditions => ['last_send_attempt < ?', Time.now.to_i - 300] }
    options[:limit] = batch_size unless batch_size.nil?
    mail = email_class.find :all, options

    log "found #{mail.length} emails to send"
    mail
  end

  ##
  # Installs signal handlers to gracefully exit.

  def install_signal_handlers
    trap 'TERM' do do_exit end
    trap 'INT'  do do_exit end
  end

  ##
  # Logs +message+ if verbose

  def log(message)
    $stderr.puts message if @verbose
    ActionMailer::Base.logger.info "ar_sendmail: #{message}"
  end

  ##
  # Scans for emails and delivers them every delay seconds.  Only returns if
  # once is true.

  def run
    install_signal_handlers

    loop do
      now = Time.now
      begin
        cleanup
        deliver find_emails
      rescue ActiveRecord::Transactions::TransactionError
      end
      break if @once
      sleep @delay if now + @delay > Time.now
    end
  end

  ##
  # Proxy to ActionMailer::Base::smtp_settings.  See
  # http://api.rubyonrails.org/classes/ActionMailer/Base.html
  # for instructions on how to configure ActionMailer's SMTP server.
  #
  # Falls back to ::server_settings if ::smtp_settings doesn't exist for
  # backwards compatibility.

  def smtp_settings
    ActionMailer::Base.smtp_settings rescue ActionMailer::Base.server_settings
  end

end

