require 'logger'
require 'net/http'
require 'json'
require 'em-http-request'

module Transmission
  class Client
    def initialize rpc, username, password
      @uri = URI.parse(rpc)
      @rpc = rpc
      @username = username
      @password = password
      @x_transmission_session_id = nil
      @callbacks = {}

      @log = Logger.new(STDOUT)
    end

    def session_set arguments
      body = {
        :method => 'session-set',
        :arguments => arguments
      }

      json_request(body) { |response| yield response }
    end

    def session_get
      body = {
        :method => 'session-get'        
      }

      json_request(body) { |response| yield response }
    end

    def blocklist_update
      body = {
        :method => 'blocklist-update'
      }

      json_request(body) { |response| yield response }
    end

    def port_test
      body = {
        :method => 'port-test'
      }

      json_request(body) { |response| yield response }
    end

    def session_stats
      body = {
          :method => :'session-stats'
      }

      json_request(body) { |response| yield response }
    end   

    def get fields, id = nil
      body = {
          :method => :'torrent-get',
          :arguments => {
              :fields => fields
          }
      }
      body[:arguments][:ids] = format_id(id) unless id.nil?

      json_request(body) { |response| yield response }
    end

    def start id
      body = {
          :method => 'torrent-start',
          :arguments => {
              :ids => format_id(id)
          }
      }

      json_request(body) { |response| yield response }
    end

    def start_now id
      body = {
          :method => 'torrent-start-now',
          :arguments => {
              :ids => format_id(id)
          }
      }

      json_request(body) { |response| yield response }
    end

    def stop id
      body = {
          :method => 'torrent-stop',
          :arguments => {
              :ids => format_id(id)
          }
      }

      json_request(body) { |response| yield response }
    end

    def verify id
      body = {
          :method => 'torrent-verify',
          :arguments => {
              :ids => format_id(id)
          }
      }

      json_request(body) { |response| yield response }
    end

    def reannounce id
      body = {
          :method => 'torrent-reannounce',
          :arguments => {
              :ids => format_id(id)
          }
      }

      json_request(body) { |response| yield response }
    end

    def set id, property, value
      body = {
        :method => 'torrent-set',
        :arguments => {
          :ids => format_id(id),
          property.to_sym => value
        }
      }

      json_request(body) { |response| yield response }
    end

    def add_as_file file_name, arguments = nil
      body = {
        :method => 'torrent-add',
        :arguments => {
          :filename => file_name
        }
      }
      body.arguments.merge(arguments) if !arguments.nil? && arguments.is_a?(Hash)
      
      json_request(body) { |response| yield response }
    end

    def add_as_metainfo meta_info, arguments
      body = {
        :method => 'torrent-add',
        :arguments => {
          :metainfo => meta_info
        }
      }
      body.arguments.merge(arguments) if !arguments.nil? && arguments.is_a?(Hash)

      json_request(body) { |response| yield response }
    end

    def remove id = nil, delete_local_data = false
      body = {
        :method => 'torrent-remove',
        :arguments => {
          :delete_local_data => delete_local_data
        }
      }
      body[:arguments][:ids] = format_id(id) unless id.nil?

      json_request(body) { |response| yield response }
    end

    def move location, id = nil, move = true
      body = {
        :method => 'torrent-set-location',
        :arguments => {
          :location => location
        }
      }
      body[:arguments][:ids] = format_id(id) unless id.nil?
      body[:arguments][:move] = move unless move.nil?

      json_request(body) { |response| yield response }
    end

    %w(added deleted moved stopped start_wait started seed_wait seeded exists check_wait checked progress).each do |c|
      name = c.to_sym
      define_method name do |&block|
        @callbacks[name] = block
        activate_callbacks(name)
      end
    end

    def stop_callbacks
      @callbacks_timer.cancel if @callbacks_timer
    end

    private
    def activate_callbacks activator
      return if @callbacks_timer
      @callbacks_timer = EventMachine::PeriodicTimer.new(1) do
        get([:id, :name, :hashString, :status, :downloadedEver]) do |response|
          response.error { |result| raise :error } 
          response.unauthorization { |result| raise :unauthorization }

          response.success do |result|
            torrents = result[:arguments][:torrents]
            if @torrents
              watch_torrents = {}
              torrents.each do |t|
                if @torrents.include?(t[:hashString])
                  wt = @torrents[t[:hashString]]

                  safe_callback_call(:moved, t)      unless t[:downloadDir] == wt[:downloadDir]                   
                  safe_callback_call(:progress, t)   unless t[:downloadedEver] == wt[:downloadedEver]
                  safe_callback_call(:stopped, t)    if status_changed?(0, t, wt)
                  safe_callback_call(:check_wait, t) if status_changed?(1, t, wt)
                  safe_callback_call(:checked, t)    if status_changed?(2, t, wt)
                  safe_callback_call(:start_wait, t) if status_changed?(3, t, wt)
                  safe_callback_call(:started, t)    if status_changed?(4, t, wt)
                  safe_callback_call(:seed_wait, t)  if status_changed?(5, t, wt)
                  safe_callback_call(:seeded, t)     if status_changed?(6, t, wt)
                  
                  watch_torrents[t[:hashString]] = t
                  @torrents.delete(t[:hashString])
                else
                  watch_torrents[t[:hashString]] = t
                  safe_callback_call(:added, t)
                end
              end
              @torrents.each { |hash, t| safe_callback_call(:deleted, t) }

              @torrents = watch_torrents
            else
              @torrents = {}
              torrents.each do |t| 
                @torrents[t[:hashString]] = t
                safe_callback_call(:exists, t)
              end
            end
          end
        end
      end
    end

    def status_changed? status_code, one_torrent, two_torrent
      one_torrent[:status].to_i == status_code && two_torrent[:status].to_i != status_code
    end

    def safe_callback_call cb, *args
      return unless @callbacks
      @callbacks[cb].call(args) if @callbacks.include?(cb)
    end

    def method_missing m, *args, &block
      if (m.to_s =~ /_callback$/)
        puts "#{m} is callback"
      end
    end
    
    def json_request body
      push(body) do |response| 
        yield response
      end
    end

    def format_id id
      case id
        when Hash then id.to_a
        when Array then id
        else [id]
      end
    end

    def push body, options = nil
      options = {:head => {}, :body => body.to_json}
      options[:head][:authorization] = [@username, @password] unless @username.nil? && @password.nil?
      options[:head][:'x-transmission-session-id'] = @x_transmission_session_id unless @x_transmission_session_id.nil?

      request = EventMachine::HttpRequest.new(@rpc).post(options)      
      
      request.callback do
        if request.response_header.status == 409
          @x_transmission_session_id = request.response_header['x-transmission-session-id']
          push(body) { |response| yield response }
        else
          yield Transmission::Response.new request.response_header.status, request.response
        end
      end

      request.errback do |error|
        yield Transmission::Response.new request.response_header.status, request.response
      end
    end
  end

  class Response
    def initialize code, response
      @code = code
      @response = response
    end

    def success &block
      return unless block
      block.call(build_json) if @code == 200 && can_build_json?
      self
    end

    def error &block
      return unless block
      block.call(@response) unless @code == 200 && can_build_json?
      self      
    end

    def unauthorization &block
      return unless block
      block.call(build_json) if @code == 401 && can_build_json?
      self
    end

    private
    def build_json
      JSON.parse(@response, :symbolize_names => true)
    end

    def can_build_json?
      begin
        build_json
        true
      rescue JSON::ParserError
        false
      end
    end
  end

  class Torrent
    def initialize fields = {}
      @fields = fields
    end
    
    def [] key
      @fields[key]
    end

    def []= key, value
      @fields[key] = value
    end
  end
end

EventMachine.run do
  client = Transmission::Client.new 'http://localhost:9091/transmission/rpc', 'transmission', '123456'  
  client.get([:id, :name, :hashString, :status, :downloadedEver]) do |r|   
    r.success { |result| puts result[:arguments][:torrents].map { |t| t[:downloadedEver] } }
    r.error { |result| puts :error }
    r.unauthorization { |result| puts :unauthorization }
  end
  client.added do |torrent|
    puts "New torrent: #{torrent.inspect}"
  end
  client.exists do |torrent|
    puts "Exists torrent on transmission connection init: #{torrent.inspect}"
  end
  client.deleted do |torrent|
    puts "Torrent was deleted: #{torrent.inspect}"
  end
  client.stopped do |torrent|
    puts "Torrent was stopped: #{torrent.inspect}"
  end
  client.started { |t| puts "Torrent started: #{t.inspect}" }
  client.seeded { |t| puts "Torrent seeded: #{t.inspect}" }
  client.progress { |t| puts "Torrent #{t[0][:id]} progress: #{t[0][:downloadedEver]}" }
end
