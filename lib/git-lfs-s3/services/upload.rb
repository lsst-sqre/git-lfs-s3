# frozen_string_literal: true

require 'git-lfs-s3/services/upload/base'
require 'git-lfs-s3/services/upload/object_exists'
require 'git-lfs-s3/services/upload/upload_required'

module GitLfsS3
  module UploadService
    module_function

    extend AwsHelpers

    MODULES = [
      ObjectExists,
      UploadRequired
    ].freeze

    def service_for(data)
      req = MultiJson.load data.tap(&:rewind).read
      object = object_data(req['oid'])

      MODULES.each do |mod|
        return mod.new(req, object) if mod.should_handle?(req, object)
      end

      nil
    end
  end
end
