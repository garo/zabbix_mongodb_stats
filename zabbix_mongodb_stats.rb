#!/usr/bin/env ruby
 
require 'optparse'
require 'rubygems'
require 'open4'
require 'mongo'
require 'daemons'
require 'ostruct'
require 'logger'
 
class MongoStats < Logger::Application
  def initialize(args)
    super(self.class)
    @options = OpenStruct.new(:daemonize => true)
    @options.hostname = `hostname`.strip
    opts = OptionParser.new do |opts|
      opts.banner = "Usage: zabbix_mongodb_stats.rb [options]"
      opts.separator ''
      opts.on('-N','--no-daemonize',"Don't run as a daemon") do
        @options.daemonize = false
      end
      opts.on('-s', '--host HOST', "Hostname used in stats") do |f|
         @options.hostname = f
      end
      opts.on('-h', '--db-host HOSTNAME', "MongoDB hostname (default: localhost)") do |f|
        @options.dbhost = f
      end
      opts.on('-p', '--db-port PORTNUMBER', "MongoDB port (default: 27017)") do |f|
        @options.dbport = f
      end
      opts.on('-z', '--zabbix-server HOSTNAME', "Mandatory Zabbix server name") do |f|
        @options.zabbix = f
      end
      opts.on('-D','--debug',"Run in debug mode") do
        @options.debug = true
      end
    end
    @args = opts.parse!(args)
  end
 
  def run
    options = {:ARGV => @args, :ontop => !@options.daemonize, :pidfile_dir => "/tmp" }
    options.merge!({ :log_output => true }) if @options.daemonize == false
 
   Daemons.run_proc('zabbix_mongodb_stats', options) do
      @mongo = Mongo::Connection.new(@options.dbhost, @options.dbport, :slave_ok => true)
      STDOUT.sync = true
      loop do
 
        unless @mongo.active?
          @mongo.reconnect
          sleep 5
        end
 
        serverstats = self.mongodb_server_status
 
        # No replication stats if connected to mongos
        if iam_mongos?
          stats = serverstats
        else
          replstats = self.mongodb_repl_status
          stats = serverstats + replstats
        end
 
        # Send data to zabbix
        zbx = self.zabbix_sender(stats)
        until zbx
          sleep(10) ;; zbx = self.zabbix_sender(stats)
        end
 
        sleep(10)
      end
    end
  end
 
  protected
 
  def mongodb_run_command(database, cmd)
    begin
      puts "Connecting to MongoDB server #{@options.dbhost}:#{@options.dbport} (#{database})" if @options.debug
      db = @mongo.db(database)
      puts " * Running command (#{cmd.inspect})\n" if @options.debug
      db.command(cmd)
    rescue
      puts "Could not connect to MongoDB server (#{@options.dbhost}:#{@options.dbport}): #{}"
      return false
    end
  end
 
  def mongodb_server_status
    cmd = BSON::OrderedHash.new
    cmd['serverStatus'] = 1
    cmd['repl'] = 1
    serverstats = mongodb_run_command('test', cmd)
    until serverstats
      sleep(5) ;; serverstats = mongodb_run_command('test', cmd)
    end
    parse_server_stats(serverstats)
  end
 
  def mongodb_repl_status
    cmd = BSON::OrderedHash.new
    cmd['replSetGetStatus'] = 1
    replstats = mongodb_run_command('admin', cmd)
    until replstats
      sleep(5) ;; replstats = mongodb_run_command('admin', cmd)
    end
    parse_repl_stats(replstats)
  end
 
  def iam_mongos?
    cmd = BSON::OrderedHash.new
    cmd['isMaster'] = 1
    res = mongodb_run_command('test', cmd)
    if res['ismaster'] == true && res['secondary'].nil?
      return true
    else
      return false
    end
  end
 
  def iam_primary?
    cmd = BSON::OrderedHash.new
    cmd['isMaster'] = 1
    res = mongodb_run_command('test', cmd)
    if res['secondary'].nil? # mongos
      return false
    elsif res['ismaster'] == true
      return true
    elsif res['secondary'] == true
      return false
    else
      return false
    end
  end
 
  def parse_server_stats(serverstats)
    # Parses data to "hostname item.key.subkey value" format
    stats = String.new
    flatkeys = ["version", "process", "uptime", "uptimeEstimate", "localTime","writeBacksQueued", "ok"]
    singlekeys = ["mem", "connections", "cursors", "backgroundFlushing", "network", "opcounters", "asserts", "extra_info"]
    doublekeys = ["indexCounters", "globalLock"]
    doublekeys_subs = ['currentQueue', 'activeClients', 'btree']
    serverstats.each_key do |s|
      if flatkeys.include?(s)
        stats << "#{@options.hostname} mongodb.#{s} #{serverstats[s]}\n"
      elsif singlekeys.include?(s)
        serverstats[s].each do |key,value|
          stats << "#{@options.hostname} mongodb.#{s}.#{key} #{value}\n"
        end
      elsif doublekeys.include?(s)
        serverstats[s].each do |key,value|
          if doublekeys_subs.include?(key)
            serverstats[s][key].each do |k,v|
              stats <<"#{@options.hostname} mongodb.#{s}.#{key}.#{k} #{v}\n"
            end
          else
            stats <<"#{@options.hostname} mongodb.#{s}.#{key} #{value}\n"
          end
        end
      end
    end
    # Additional opcounter stats for primary nodes (aggregated graphs)
    if iam_primary?
      serverstats['opcounters'].each do |key, value|
        stats << "#{@options.hostname} mongodb.primary.opcounters.#{key} #{value}\n"
      end
    end
 
    return stats
  end
 
  def parse_repl_stats(replstats)
    # Find master optimeDate first
    replstats['members'].each do |member|
      if member['state'].to_i == 1
        $master_opt = member['optimeDate']
      end
    end
 
    # Parses data to "hostname item.key.subkey value" format
    stats = String.new
    replstats['members'].each do |member|
      if member['name'].split('.').first == @options.hostname
        repl_lag = ($master_opt - member['optimeDate'])
        stats << "#{@options.hostname} mongodb.health #{member['health'].to_i}\n"
        stats << "#{@options.hostname} mongodb.state #{member['state']}\n"
        stats << "#{@options.hostname} mongodb.repl_lag #{repl_lag}\n"
      end
    end
    return stats
  end
 
  def zabbix_sender(stats)
    status = Open4::popen4("zabbix_sender -v -z #{@options.zabbix} -r -i -") do |pid, stdin, stdout, stderr|
      puts stats if @options.debug
      stdin.puts "#{stats}"
      stdin.close
      puts "stdout     : #{ stdout.read.strip }" if @options.debug
    end
    if status.exitstatus.to_i == 255
      puts "Could not connect to Zabbix server (#{@options.zabbix})"
      return false
    end
    return true
  end
end
 
mongostats = MongoStats.new(ARGV)
mongostats.run
