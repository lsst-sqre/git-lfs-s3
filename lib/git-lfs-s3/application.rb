require 'date'

module GitLfsS3
  class Application < Sinatra::Application
    include AwsHelpers

    class << self
      attr_reader :auth_callback

      def on_authenticate(&block)
        @auth_callback = block
      end

      def authentication_enabled?
        !auth_callback.nil?
      end

      def perform_authentication(username, password, is_safe)
        auth_callback.call(username, password, is_safe)
      end
    end

    configure do
      disable :sessions
      enable :logging
    end

    helpers do
      def logger
        settings.logger
      end
    end

    def authorized?
      @auth ||=  Rack::Auth::Basic::Request.new(request.env)
      @auth.provided? && @auth.basic? && @auth.credentials && self.class.auth_callback.call(
        @auth.credentials[0], @auth.credentials[1], request.safe?
      )
    end

    def protected!
      unless authorized?
        response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
        throw(:halt, [401, "Invalid username or password"])
      end
    end

    get '/' do
      "Git LFS S3 is online."
    end

    def valid_obj?(obj)
      # Validate that size >= 0 and oid is a SHA256 hash.
      begin
        if obj[:size] >= 0
          oid = obj[:oid]
          valid = (oid.hex.size <= 32) and (oid.size == 64) and (oid =~ /^[0-9a-f]+$/)
        end
      end
    end

    def expire_at()
      DateTime.now.next_day.to_time.utc.iso8601
    end

    def obj_download(authenticated, obj, obj_json)
      # Format a single download object.
      oid = obj_json[:oid]
      size = obj_json[:size]
      {
        'oid'           => oid,
        'size'          => size,
        'authenticated' => authenticated,
        'actions'       => {
          'download'    => {
            'href'      => obj.presigned_url(:get,
                                             :expires_in => 86400),
          },
        },
        'expires_at'    => expire_at,
      }
    end

    def obj_upload(authenticated, obj, obj_json)
      # Format a single upload object.
      oid = obj_json[:oid]
      size = obj_json[:size]
      {
        'oid'           => oid,
        'size'          => size,
        'authenticated' => authenticated,
        'actions'       => {
          'upload'      => {
            'href'      => obj.presigned_url(:put,
                                             acl: 'public-read',
                                             :expires_in => 86400),
          },
          'expires_at'  => expire_at,
        },
      }
    end

    def obj_error(error, message, obj_json)
      # Format a single error object.
      {
        'oid'       => obj_json[:oid],
        'size'      => obj_json[:size],
        'error'     => {
          'code'    => error,
          'message' => message,
        },
      }
    end

    def download(authenticated, params)
      # Handle git-lfs batch downloads.
      objects = []
      params[:objects].each do |obj_json|
        obj_json = indifferent_params(obj_json)
        obj = object_data(obj_json[:oid])
        if valid_object?(obj_json)
          if obj.exists?
            objects.push(obj_download(authenticated, obj, obj_json))
          else
            objects.push(obj_error(404, 'Object does not exist', obj_json))
          end
        else
          objects.push(obj_error(422, 'Validation error', obj_json))
        end
      end
      objects
    end

    def upload(authenticated, params)
      # Handle git-lfs batch uploads.
      objects = []
      params[:objects].each do |obj_json|
        obj_json = indifferent_params(obj_json)
        obj = object_data(obj_json[:oid])
        if valid_obj?(obj_json)
          if obj.exists?
            objects.push(obj_download(authenticated, obj, obj_json))
          else
            objects.push(obj_upload(authenticated, obj, obj_json))
          end
        else
          objects.push(obj_error(422, 'Validation error', obj_json))
        end
      end
      objects
      end

    def lfs_resp(objects)
      # Successful git-lfs batch response.
      status(200)
      resp = {
        'transfer' => 'basic',
        'objects' => objects
      }
      body MultiJson.dump(resp)
    end
    
    def error_resp(status_code, message)
      # Error git-lfs batch response.
      status(status_code)
      resp = {
        'message' => message,
        'request_id' => SecureRandom::uuid
      }
      body MultiJson.dump(resp)
    end
    
    post '/objects/batch', provides: 'application/vnd.git-lfs+json' do
      # git-lfs batch API
      authenticated = authorized?
      params = indifferent_params(JSON.parse(request.body.read))
      logger.debug params
      if params[:operation] == 'download'
        objects = download(authenticated, params)
      elsif params[:operation] == 'upload'
        if authenticated
          objects = upload(authenticated, params)
          lfs_resp(objects)
        else
          objects = nil
          error_resp(401, 'Credentials needed')
        end
      else
        error_resp(422, 'Validation error')
      end
    end

    get "/objects/:oid", provides: 'application/vnd.git-lfs+json' do
      object = object_data(params[:oid])

      if object.exists?
        status 200
        resp = {
          'oid' => params[:oid],
          'size' => object.size,
          '_links' => {
            'self' => {
              'href' => File.join(settings.server_url, 'objects', params[:oid])
            },
            'download' => {
              # TODO: cloudfront support
              'href' => object_data(params[:oid]).presigned_url(:get)
            }
          }
        }

        body MultiJson.dump(resp)
      else
        status 404
        body MultiJson.dump({message: 'Object not found'})
      end
    end

    def public_read_grant
      grantee = Aws::S3::Types::Grantee.new(
        display_name: nil, email_address: nil, id: nil, type: nil,
        uri: "http://acs.amazonaws.com/groups/global/AllUsers")
      Aws::S3::Types::Grant.new(grantee: grantee, permission: "READ")
    end

    before do
      pass if request.safe? and settings.public_server
      protected!
    end

    post "/objects", provides: 'application/vnd.git-lfs+json' do
      logger.debug headers.inspect
      service = UploadService.service_for(request.body)
      logger.debug service.response
      
      status service.status
      body MultiJson.dump(service.response)
    end

    post '/verify', provides: 'application/vnd.git-lfs+json' do
      data = MultiJson.load(request.body.tap { |b| b.rewind }.read)
      object = object_data(data['oid'])
      if not object.exists?
        status 404
      end
      if settings.public_server and settings.ceph_s3
        if not object.acl.grants.include?(public_read_grant)
          object.acl.put(acl: "public-read")
        end
      end
      if object.size == data['size']
        status 200
      end
    end
  end
end
