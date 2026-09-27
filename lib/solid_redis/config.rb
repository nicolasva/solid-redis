# frozen_string_literal: true

require "uri"

module SolidRedis
  class Config
    DEFAULT_TIMEOUT = 1.0
    DEFAULT_PORT = 6379
    UNSPECIFIED = Object.new.freeze

    attr_reader :host, :port, :path, :username, :password, :db,
      :connect_timeout, :read_timeout, :write_timeout, :reconnect_attempts,
      :ssl_params

    def initialize(
      url: nil,
      host: "127.0.0.1",
      port: DEFAULT_PORT,
      path: nil,
      username: nil,
      password: nil,
      db: UNSPECIFIED,
      timeout: DEFAULT_TIMEOUT,
      connect_timeout: timeout,
      read_timeout: timeout,
      write_timeout: timeout,
      reconnect_attempts: 1,
      ssl: false,
      ssl_params: nil,
      callbacks: nil
    )
      if url
        values = parse_url(url)
        host = values[:host]
        port = values[:port]
        path = values[:path]
        username ||= values[:username]
        password ||= values[:password]
        db = values[:db] if db.equal?(UNSPECIFIED) && !values[:db].nil?
        ssl ||= values[:ssl]
      end
      db = 0 if db.equal?(UNSPECIFIED)

      @host = String(host).dup.freeze unless path
      @port = Integer(port) unless path
      @path = String(path).dup.freeze if path
      @username = String(username).dup.freeze if username
      @password = String(password).dup.freeze if password
      @db = Integer(db)
      @connect_timeout = positive_float(connect_timeout, :connect_timeout)
      @read_timeout = positive_float(read_timeout, :read_timeout)
      @write_timeout = positive_float(write_timeout, :write_timeout)
      @reconnect_attempts = Integer(reconnect_attempts)
      raise ArgumentError, "reconnect_attempts must not be negative" if @reconnect_attempts.negative?

      @ssl = !!ssl
      @ssl_params = Shareable.copy(ssl_params, label: "ssl_params") if ssl_params
      @callbacks = Shareable.copy(callbacks, label: "callbacks") if callbacks
      @server_key = [@path, @host, @port].freeze
      Ractor.make_shareable(self)
    end

    def ssl?
      @ssl
    end

    def sentinel?
      false
    end

    def resolved?
      true
    end

    def server_key
      @server_key
    end

    def server_url
      return "unix://#{path}?db=#{db}" if path

      scheme = ssl? ? "rediss" : "redis"
      address = host.include?(":") ? "[#{host}]" : host
      "#{scheme}://#{address}:#{port}/#{db}"
    end

    def new_client(**options)
      Client.new(self, **options)
    end

    def new_pool(**options)
      Pool.new(self, **options)
    end

    def new_subscription(**options)
      Subscription.new(self, **options)
    end

    def notify(event, *arguments)
      return unless @callbacks&.respond_to?(event)

      @callbacks.respond_with(event, *arguments)
    end

    def inspect
      "#<#{self.class.name} #{server_url}>"
    end

    private

    def parse_url(url)
      uri = URI.parse(url)
      unless %w[redis rediss unix].include?(uri.scheme)
        raise ArgumentError, "Unsupported Redis URL scheme: #{uri.scheme.inspect}"
      end

      if uri.scheme == "unix"
        {
          path: uri.path,
          username: decoded(uri.user),
          password: decoded(uri.password),
          db: query_db(uri),
          ssl: false,
        }
      else
        {
          host: uri.host,
          port: uri.port || DEFAULT_PORT,
          username: decoded(uri.user),
          password: decoded(uri.password),
          db: path_db(uri) || query_db(uri),
          ssl: uri.scheme == "rediss",
        }
      end
    rescue URI::InvalidURIError => error
      raise ArgumentError, "Invalid Redis URL: #{error.message}", cause: error
    end

    def path_db(uri)
      return if uri.path.nil? || uri.path.empty? || uri.path == "/"

      Integer(uri.path.delete_prefix("/"))
    end

    def query_db(uri)
      return unless uri.query

      value = URI.decode_www_form(uri.query).to_h["db"]
      Integer(value) if value
    end

    def decoded(value)
      URI.decode_www_form_component(value) if value
    end

    def positive_float(value, name)
      value = Float(value)
      raise ArgumentError, "#{name} must be positive" unless value.positive?

      value
    end
  end
end
