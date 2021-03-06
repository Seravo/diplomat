require 'base64'
require 'faraday'

module Diplomat
  class Kv < Diplomat::RestClient

    attr_reader :key, :value, :raw, :list, :results

    # Get a value by its key
    # @param key [String] the key
    # @return [String] The base64-decoded value associated with the key
    def get key
      @key = key
      url = ["/v1/kv/#{@key}"]
      url += check_acl_token unless check_acl_token.nil?
      @raw = @conn.get concat_url url
      parse_body
      return_value
    end

    # Associate a value with a key
    # @param key [String] the key
    # @param value [String] the value
    # @param options [Hash] the query params
    # @option options [Integer] :cas The modify index
    # @return [Bool] Success or failure of the write (can fail in c-a-s mode)
    def put key, value, options=nil

      # This will fail if both are not strings.
      # use #to_s function to both
      @options = options
      @raw = @conn.put do |req|
        url = ["/v1/kv/#{key.to_s}"]
        url += check_acl_token unless check_acl_token.nil?
        url += use_cas(@options) unless use_cas(@options).nil?
        req.url concat_url url
        req.body = value.to_s
      end
      if @raw.body == "true"
        @key   = key
        @value = value
      end
      @raw.body == "true"
    end

    # Delete a value by its key
    # @param key [String] the key
    # @return [OpenStruct]
    def delete key
      @key = key
      url = ["/v1/kv/#{@key}"]
      url += check_acl_token unless check_acl_token.nil?
      @raw = @conn.delete concat_url url
    end

    # List all keys with matching paths
    # @param key [String] the key
    # @return [Array] The list of keys with matching value
    def list_keys key,skip_directories=true
      @key = key
      url = ["/v1/kv/#{@key}","keys"]
      url += check_acl_token unless check_acl_token.nil?
      @raw = @conn.get concat_url url
      parse_list(skip_directories)
      @list
    end

    # Get everything matching the key value, this is fast!
    # @param key [String] the key
    # @return [Hash] The list of keys with matching value
    def get_recursive key
      @key = key
      url = ["/v1/kv/#{@key}/","recurse"]
      url += check_acl_token unless check_acl_token.nil?
      @raw = @conn.get concat_url url
      parse_results
      @results
    end

    # Get everything matching the key value, this is fast!
    # @param key [String] the key
    # @return [Hash] The list of keys with matching value
    def delete_recursive key
      @key = key
      url = ["/v1/kv/#{@key}","recurse"]
      url += check_acl_token unless check_acl_token.nil?
      @raw = @conn.delete concat_url url
    end

    # Put a big hash (eg. yaml file) into consul with namespace key, this is slow...
    # @param namespace [String] the namespace for values (the key)
    # @param hash [String] nested hash with values
    # @option options [Integer] :cas The modify index
    # @return [Bool] Success or failure of the write (can fail in c-a-s mode)
    def put_recursive namespace, hash, options=nil
      @options = options
      # remove trailing slash if any
      namespace.gsub(/\/+$/, '')
      key_values = nested_hash_to_key_value_hash(hash,{},namespace)

      key_values.each do |k,v|

        # If value is nil act like key is directory
        k = "#{k}/" if v.nil?

        self.put k,v
      end
    end

    # @note This is sugar, see (#get)
    def self.get *args
      Diplomat::Kv.new.get *args
    end

    # @note This is sugar, see (#put)
    def self.put *args
      Diplomat::Kv.new.put *args
    end

    # @note This is sugar, see (#delete)
    def self.delete *args
      Diplomat::Kv.new.delete *args
    end

    private

    # Parse the body, apply it to the raw attribute
    def parse_body
      @raw = JSON.parse(@raw.body).first
    end

    # Parse the body of list, keep it as an array
    def parse_list(skip_directories=true)
      @list = JSON.parse(@raw.body)
      @list.delete_if { |x| x.end_with? '/' } if skip_directories
    end

    # Parse consul '?recursive' answer
    def parse_results
      responses = JSON.parse(@raw.body)
      @results = {}
      responses.each do |item|
        # Remove the starting path from the key
        # So for example if we recursively searched everything under domains/example.com/
        # We will return just the things starting from domains/example.com/ but without the domains/example.com/ part
        item['Key'].slice!(@key)
        item['Key'].slice!('/')

        @value = item['Value']
        @value = Base64.decode64(@value) unless @value.nil?

        # Values can be json so try to parse that too
        begin
          @value = JSON.parse(@value) unless @value.nil?
        rescue JSON::ParserError => e
          #Not JSON string
        end

        # Split path/to/key into array and turn it into hash
        # Point that hash into value
        hash = item['Key'].split('/').to_deep_hash(@value)
        # Merge everything into big hash
        @results.deep_merge!(hash)
      end
      @results
    end

    # Get the key from the raw output
    def return_key
      @key = @raw["Key"]
    end

    # Get the value from the raw output
    def return_value
      @value = @raw["Value"]
      @value = Base64.decode64(@value) unless @value.nil?
    end

    # Turn big nested hash into nice namespaced #{k}=#{v} hashes
    def nested_hash_to_key_value_hash(source, target = {}, namespace = nil)
      prefix = "#{namespace}/" if namespace
      case source
      when Hash
        source.each do |key, value|
          nested_hash_to_key_value_hash(value, target, "#{prefix}#{key}")
        end
      when Array
        # If all elements are simple convert to json array
        if source.all? {|element| element.is_a? String or element.is_a? Numeric}
          target[namespace] = source.to_json
        else
          # Otherwise keep converting to nested paths
          source.each_with_index do |value, index|
            nested_hash_to_key_value_hash(value, target, "#{prefix}#{index}")
          end
        end
      else
        target[namespace] = source
      end
      target
    end

    def check_acl_token
      ["token=#{Diplomat.configuration.acl_token}"] if Diplomat.configuration.acl_token
    end

    def use_cas(options)
      ["cas=#{options[:cas]}"] if options && options[:cas]
    end
  end
end
