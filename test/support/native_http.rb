# frozen_string_literal: true

require "socket"
require "timeout"
require "openssl"

# Real loopback HTTP, not WebMock: Rust HTTP never passes through Net::HTTP.
class NativeHTTP
  attr_reader :requests, :url

  def initialize(statuses: [ 200 ], delay: 0, headers: {}, tls: false)
    @listener = TCPServer.new("127.0.0.1", 0)
    @url = "#{tls ? 'https' : 'http'}://127.0.0.1:#{@listener.addr[1]}"
    @server = tls ? OpenSSL::SSL::SSLServer.new(@listener, tls_context) : @listener
    @requests = Queue.new
    @statuses = statuses
    @delay = delay
    @headers = headers
    @worker = Thread.new do
      loop do
        begin
          socket = @server.accept
        rescue OpenSSL::SSL::SSLError
          # Certificate rejection is an expected result in TLS boundary tests.
          next
        end
        handle(socket)
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def tls_context
    # Real TLS with a deliberately untrusted, ephemeral fixture certificate.
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = factory.issuer_certificate = cert
    cert.add_extension(factory.create_extension("subjectAltName", "IP:127.0.0.1"))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    OpenSSL::SSL::SSLContext.new.tap do |context|
      context.cert = cert
      context.key = key
    end
  end

  def handle(socket)
    first = socket.gets
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip
    end
    body = socket.read(headers.fetch("content-length", "0").to_i)
    @requests << { method: first.split[0], path: first.split[1], headers: headers, body: body }
    sleep @delay if @delay.positive?
    status = @statuses.size > 1 ? @statuses.shift : @statuses.first
    extra = @headers.map { |key, value| "#{key}: #{value}\r\n" }.join
    socket.write("HTTP/1.1 #{status} Fixture\r\nContent-Length: 2\r\nConnection: close\r\n#{extra}\r\n{}")
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil
  ensure
    socket&.close
  end

  def next_request
    Timeout.timeout(5) { @requests.pop }
  end

  def dsn(project = 123, key: "public")
    @url.sub("://", "://#{key}@") + "/#{project}"
  end

  def close
    @listener.close
    @worker.join(1)
  end
end

NATIVE_HTTP_FIXTURE = NativeHTTP.new
Minitest.after_run { NATIVE_HTTP_FIXTURE.close }
