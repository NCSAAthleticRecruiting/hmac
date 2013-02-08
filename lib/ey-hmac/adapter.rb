# This class is responsible for forming the canonical string to used to sign requests
# @abstract override methods {#method}, {#path}, {#body}, {#content_type} and {#content_digest}
class Ey::Hmac::Adapter
  AUTHORIZATION_REGEXP = /\w+ ([^:]+):(.+)$/

  autoload :Rack, "ey-hmac/adapter/rack"
  autoload :Faraday, "ey-hmac/adapter/faraday"

  attr_reader :request, :options, :authorization_header, :service, :signature_digest_header

  # @param [Object] request signer-specific request implementation
  # @option options [Integer] :version signature version
  # @option options [String] :authorization_header ('Authorization') Authorization header key.
  # @option options [String] :server ('EyHmac') service name prefixed to {#authorization}. set to {#service}
  # @option options [String] :signature_digest_header ('Signature-Hash') hashing function to use
  # @option options [String] :signature_digest_method ('SHA256') hashing function performed on the signature
  def initialize(request, options={})
    @request, @options = request, options

    @authorization_header    = options[:authorization_header]     || 'Authorization'
    @service                 = options[:service]                  || 'EyHmac'
    @signature_digest_header = options[:signature_digest_header]  || 'Signature-Digest'
    @signature_digest_method = (options[:signature_digest_method] || 'SHA256').to_s.upcase
  end

  # In order for the server to correctly authorize the request, the client and server MUST AGREE on this format
  #
  # default canonical string formation is '{#method}\\n{#content_type}\\n{#content_digest}\\n{#date}\\n{#path}'
  # @return [String] canonical string used to form the {#signature}
  # @api public
  def canonicalize
    [method, content_type, content_digest, date, path].join("\n")
  end

  # @param [String] key_secret private HMAC key
  # @return [String] HMAC signature of {#request}
  # @api public
  def signature(key_secret)
    Base64.encode64(OpenSSL::HMAC.digest(OpenSSL::Digest::Digest.new(signature_digest_method), key_secret, canonicalize)).strip
  end

  # @abstract
  # @return [String] signature digest method from {#signature_digest_header} or from {@signature_digest_method}
  def signature_digest_method
    raise NotImplementedError
  end

  # @param [String] key_id public HMAC key
  # @param [String] key_secret private HMAC key
  # @return [String] HMAC header value of {#request}
  # @api public
  def authorization(key_id, key_secret)
    "#{service} #{key_id}:#{signature(key_secret)}"
  end

  # @abstract
  # @return [String] upcased request verb. i.e. 'GET'
  # @api public
  def method
    raise NotImplementedError
  end

  # @abstract
  # @return [String] request path. i.e. '/blogs/1'
  # @api public
  def path
    raise NotImplementedError
  end

  # @abstract
  # Digest of body. Default is MD5.
  # @todo support explicit digest methods
  # @return [String] digest of body
  # @api public
  def content_digest
    raise NotImplementedError
  end

  # @abstract
  # @return [String] request body.
  # @return [NilClass] if there is no body or the body is empty
  # @api public
  def body
    raise NotImplementedError
  end

  # @abstract
  # @return [String] value of the Content-Type header in {#request}
  # @api public
  def content_type
    raise NotImplementedError
  end

  # @abstract
  # @return [String] value of the Date header in {#request}.
  # @see {Time#http_date}
  # @api public
  def date
    raise NotImplementedError
  end

  # @abstract used when verifying a signed request
  # @return [String] value of the {#authorization_header}
  # @api public
  def authorization_signature
    raise NotImplementedError
  end

  # @abstract
  # Add {#signature} in {#authorization_header} and {#signature_digest_method} to {#signature_digest_header}
  # @api public
  def sign!(key_id, key_secret)
    raise NotImplementedError
  end

  # Check {#authorization_signature} against calculated {#signature}
  # @yieldparam key_id [String] public HMAC key
  # @return [Boolean] true if block yields matching private key and signature matches, else false
  # @see #authenticated!
  # @api public
  def authenticated?(&block)
    authenticated!(&block)
  rescue Ey::Hmac::Error
    false
  end

  # Check {#authorization_signature} against calculated {#signature}
  # @yieldparam key_id [String] public HMAC key
  # @return [Boolean] true if block yields matching private key
  # @raise [Ey::Hmac::Error] if authentication fails
  # @api public
  def authenticated!(&block)
    if authorization_match = AUTHORIZATION_REGEXP.match(authorization_signature)
      key_id          = authorization_match[1]
      signature_value = authorization_match[2]

      if key_secret = block.call(key_id)
        calculated_signature = signature(key_secret)
        if secure_compare(signature_value, calculated_signature)
        else raise(Ey::Hmac::SignatureMismatch, "Calculated siganature #{signature_value} does not match #{calculated_signature} using #{canonicalize.inspect}")
        end
      else raise(Ey::Hmac::MissingSecret, "Failed to find secret matching #{key_id.inspect}")
      end
    else
      raise(Ey::Hmac::MissingAuthorization, "Failed to parse authorization_signature #{authorization_signature}")
    end
    true
  end
  alias authenticate! authenticated!

  # Constant time string comparison.
  # pulled from https://github.com/rack/rack/blob/master/lib/rack/utils.rb#L399
  def secure_compare(a, b)
    return false unless a.bytesize == b.bytesize

    l = a.unpack("C*")

    r, i = 0, -1
    b.each_byte { |v| r |= v ^ l[i+=1] }
    r == 0
  end
end
