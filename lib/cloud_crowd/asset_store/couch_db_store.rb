require "cgi"
require 'net/http'
require 'uri'
require 'mime/types'

module CloudCrowd
  class AssetStore
    
    # The CouchDbStore is an implementation of an AssetStore that uses a CouchDB
    # instance for storing all resulting files.
    #
    # To setup CloudCrowd for use with the CouchDBStore:
    #
    # - create a database in CouchDB
    # - set couch_url in CloudCrowd's config file to point to that database
    # - Fire up +crowd console+ and call +CloudCrowd::AssetStore::CouchDbStore::init_db+
    # 
    # The last step will create a single view used to retrieve files by action and job-Id
    # for easy cleanup.
    # 
    #  
    module CouchDbStore
      
      # Call this once in order to create the view needed for the cleanup function to work.
      def self.init_db
        RestClient.put "#{CloudCrowd.config[:couch_url]}/_design/cloudcrowd",
                       { 'views' => { 'files_by_job' => { 'map'=>'function(doc){ emit(doc.job, {rev: doc._rev}); }' } } }.to_json
      end
      
      def setup
        @base_uri = URI.parse CloudCrowd.config[:couch_url]
      end

      # Save a finished file from local storage to CouchDB.
      #
      # Each file saved is stored in a separate CouchDb document using the 'Standalone Attachments'
      # feature available in CouchDb 0.9. This way no client-side Base64 encoding is needed, speeding up things
      # with large files.
      def save(local_path, save_path)
        action, job, unit, filename = save_path.match(%r{^([^/]+)/([^/]+)/([^/]+)/(.+)})[1..4]
        uri = @base_uri.dup
        uri.path = "#{uri.path}/#{CGI::escape save_path}"
        
        Net::HTTP.start(uri.host, uri.port) do |http|
          # create the document to hold the file
          req = Net::HTTP::Put.new(uri.path, { "Content-Type" => 'application/json' })
          document = nil
          http.request(req, { :job => "#{action}/#{job}" }.to_json) do |response|
            document = JSON.parse response.body
          end
          
          # attach the file to the document
          uri.path = "#{uri.path}/#{filename}"
          puts "saving #{local_path} to #{uri.to_s}"
          File.open(local_path, 'r') do |source|
            req = Net::HTTP::Put.new( uri.path+"?rev=#{document['rev']}",
                                      { "Content-Type"   => MIME::Types.type_for(local_path),
                                        "Content-Length" => File.size(local_path).to_s } )
            req.body_stream = source
            http.request req
          end
        end
        
        return uri.to_s
      end
            
      # Remove all of a Job's resulting files from CouchDB, both intermediate and finished.
      def cleanup(job)
        docs = RestClient.get "#{@base_uri.to_s}/_design/cloudcrowd/_view/files_by_job?key=#{CGI::escape %{"#{job.action}/job_#{job.id}"}}"
        JSON.parse(docs)['rows'].each do |doc|
          RestClient.delete "#{@base_uri.to_s}/#{CGI::escape doc['id']}?rev=#{doc['value']['rev']}"
        end
      end
      
    end
    
  end
end