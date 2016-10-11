class ImportController < ApplicationController

  FILE_URL = /\Afile:\/\//

  layout nil

  skip_before_action :verify_authenticity_token, :only => [:cloud_crowd, :update_access, :upload_from_email]

  before_action :secure_only,    :only => [:upload_document]
  before_action :login_required, :only => [:upload_document]
  before_action :read_only_error if read_only?

  # Internal document upload, called from the workspace.
  def upload_document
    return bad_request unless params[:file]
    @document = Document.upload(params, current_account, current_organization)
    @project_id = params[:project]
    if params[:multi_file_upload]
      json @document
    else
      # Render the HTML/script...
    end
  end
  
  def upload_from_email
    (Rails.logger.info("Failed on secret") and return forbidden) unless correct_email_upload_secret?(params[:secret])
    # take JSON blob
    email               = params[:email]
    
    (Rails.logger.error("More than one sender in email (#{email[:from]})") and return forbidden) if email[:from].size > 1
    uploader            = email[:from].first['address']
    uploader_recipients = email[:to].map{ |blob| blob['address'] }
    
    # fetch message metadata
    s3                  = AWS::S3.new
    bucket              = s3.buckets['dc-email-uploads']
    email_metadata_path = "emails/processed/#{email['id']}/#{email['id']}.json"
    metadata            = JSON.parse(bucket.objects[email_metadata_path].read)
    recipients          = metadata['to'].map{ |blob| blob['address']}
    sender              = metadata['from'].first['address']
    
    # check for shenanigans and if someone is trying to send in json blobs for someone else's email
    return forbidden unless sender == uploader
    
    # verify recipient email address
    address_key = recipients.find do |address|
      Rails.logger.info("Checking #{address} against #{uploader_recipients}")
      uploader_recipients.include?(address) and (address.split('@').last == 'upload.documentcloud.org')
    end
    
    (Rails.logger.info("Failed on address_key (Searched through #{recipients.join(", ")})") and return forbidden) unless address_key
    # verify key against sender
    key, domain = address_key.split('@')
    
    mailbox = UploadMailbox.lookup(sender, key)
    (Rails.logger.info("Failed on mailbox match (#{sender.inspect}, #{mailbox.inspect}, #{key.inspect}, #{sender.inspect})") and return forbidden) unless mailbox and mailbox.recipient == key and mailbox.sender == sender
    
    membership = mailbox.membership
    account, organization = membership.account, membership.organization
    
    # Okay!  We're in the clear!  PROCEED WITH UPLOADS
    paths = (metadata[:file_paths] || [])
    paths.each do |file_path|
      attributes = {
        # Assume that CloudCrowd will get to the email before 24 hours are through.
        url:      bucket.objects[file_path].url_for(:read, {secure: Thread.current[:ssl], expires: 24.hours}).to_s,
        email_me: paths.size
      }
      Document.upload(attributes, account, organization)
      # this is really inefficient. fix this.
    end
    
    mailbox.upload_count += paths.size
    mailbox.save
    
    # get list of files
    file_paths = email[:files]
    
    json({message: "success!"})
  end
  
  # Returning a "201 Created" ack tells CloudCrowd to clean up the job.
  def cloud_crowd
    return forbidden unless correct_cloud_crowd_secret?(params[:secret])
    cloud_crowd_job = JSON.parse(params[:job])
    if processing_job = ProcessingJob.lookup_by_remote(cloud_crowd_job)
      processing_job.resolve(cloud_crowd_job) do |pj| 
        expire_document_cache pj.document
      end
    end
    
    #render :plain => '201 Created', :status => 201
    render :plain => "Created but don't clean up the job right now."
  end
  
  # CloudCrowd is done changing the document's asset access levels.
  # 201 created cleans up the job.
  def update_access
    return forbidden unless correct_cloud_crowd_secret?(params[:secret])
    cloud_crowd_job = JSON.parse(params[:job])
    if processing_job = ProcessingJob.lookup_by_remote(cloud_crowd_job)
      processing_job.resolve(cloud_crowd_job) do |pj| 
        expire_document_cache pj.document
      end
    end

    render :plain => '201 Created', :status => 201
  end
  
  private
  
  def correct_email_upload_secret?(secret)
    secret.kind_of? String and secret == DC::SECRETS['email_upload_secret']
  end
  
  def correct_cloud_crowd_secret?(secret)
    secret.kind_of? String and secret == DC::SECRETS['cloud_crowd_secret']
  end

  def expire_document_cache(document)
    if document
      paths = document.cache_paths + document.annotations.map(&:cache_paths)
      expire_pages paths
    end
  end
end
