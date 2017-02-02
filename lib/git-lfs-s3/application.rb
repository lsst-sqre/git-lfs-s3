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

    def valid_object?(object)
      begin
        valid = object[:size] >= 0
      rescue
        valid = false
      end
      begin        
        if valid
          oid = object[:oid].hex
          valid = oid.size == 32 && object[:oid].size == 64
        end
      rescue
        valid = false
      end
      valid
    end

    def object_download(authenticated, object, object_json)
      oid = object_json[:oid]
      size = object_json[:size]
      {
        'oid' => oid,
        'size' => size,
        'authenticated' => authenticated,
        'actions' => {
          'download' => {
            'href' => object.presigned_url(:get, :expires_in => 86400)
          }
        },
        'expires_at' => DateTime.now.next_day.to_time.utc.iso8601
      }
    end

    def object_upload(authenticated, object, object_json)
      # Format a single upload object.
      oid = object_json[:oid]
      size = object_json[:size]
      {
        'oid' => oid,
        'size' => size,
        'authenticated' => authenticated,
        'actions' => {
          'upload' => {
            'href' => object.presigned_url(:put, acl: 'public-read', :expires_in => 86400)
          }
        },
        'expires_at' => DateTime.now.next_day.to_time.utc.iso8601
      }
    end

    def object_error(error, message, object, object_json)
      {
        'oid' => object_json[:oid],
        'size' => object_json[:size],
        'error' => {
          'code' => error,
          'message' => message
        }
      }
    end

    def download(authenticated, params)
      objects = Array.new
      params[:objects].each do |object_json|
        object_json = indifferent_params object_json
        object = object_data object_json[:oid]
        if valid_object? object_json
          if object.exists?
            objects.push object_download(authenticated, object, object_json)
          else
            objects.push object_error(404, 'Object does not exist', object, object_json)
          end
        else
          objects.push object_error(422, 'Validation error', object, object_json)
        end
      end
      objects
    end

    def upload(authenticated, params)
      objects = Array.new
      params[:objects].each do |object_json|
        object_json = indifferent_params object_json
        object = object_data object_json[:oid]
        if valid_object? object_json
          if object.exists?
            objects.push object_download(authenticated, object, object_json)
          else
            objects.push object_upload(authenticated, object, object_json)
          end
        else
          objects.push object_error(422, 'Validation error', object, object_json)
        end
      end
      objects
    end

    def lfs_resp(objects)
      status 200
      resp = {
        'transfer' => 'basic',
        'objects' => objects
      }
      logger.debug resp
      body MultiJson.dump(resp)
    end
    
    def error_resp(status_code, message)
      status status_code
      resp = {
        'message' => message,
        'request_id' => SecureRandom::uuid
      }
      logger.debug resp
      body MultiJson.dump(resp)
    end
    
    post '/objects/batch', provides: 'application/vnd.git-lfs+json' do
      # Git LFS Batch API
      authenticated = authorized?
      params = indifferent_params(JSON.parse(request.body.read))
      
      if params[:operation] == 'download'
        objects = download(authenticated, params)
      elsif params[:operation] == 'upload'
        if authenticated
          objects = upload(authenticated, params)
        else
          objects = nil
        end
      end
      
      if objects
        lfs_resp(objects)
      else
        error_resp(401, 'Credentials needed')
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

    post "/objects/batch", provides: 'application/vnd.git-lfs+json' do
      logger.debug headers.inspect
      service = UploadBatchService.service_for(request.body)
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
