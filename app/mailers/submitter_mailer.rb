# frozen_string_literal: true

class SubmitterMailer < ApplicationMailer
  MAX_ATTACHMENTS_SIZE = 10.megabytes

  def invitation_email(submitter, body: nil, subject: nil)
    @current_account = submitter.submission.template.account
    @submitter = submitter
    @body = body.presence

    @email_config = AccountConfigs.find_for_account(@current_account, AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY)

    subject =
      if @email_config || subject.present?
        ReplaceEmailVariables.call(subject.presence || @email_config.value['subject'], submitter:)
      else
        'You are invited to submit a form'
      end

    mail(to: @submitter.friendly_name,
         from: from_address_for_submitter(submitter),
         subject:,
         reply_to: (submitter.submission.created_by_user || submitter.template.author)&.friendly_name)
  end

  def completed_email(submitter, user, bcc: nil)
    @current_account = submitter.submission.template.account
    @submitter = submitter
    @submission = submitter.submission
    @user = user

    Submissions::EnsureResultGenerated.call(submitter)

    @email_config = AccountConfigs.find_for_account(@current_account, AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY)

    add_completed_email_attachments!(submitter)

    subject =
      if @email_config
        ReplaceEmailVariables.call(@email_config.value['subject'], submitter:)
      else
        submitters = submitter.submission.submitters.order(:completed_at)
                              .map { |e| e.name || e.email || e.phone }.join(', ')
        %(#{submitter.submission.template.name} has been completed by #{submitters})
      end

    mail(from: from_address_for_submitter(submitter),
         to: user.friendly_name,
         bcc:,
         subject:)
  end

  def documents_copy_email(submitter, to: nil)
    @current_account = submitter.submission.template.account
    @submitter = submitter

    Submissions::EnsureResultGenerated.call(@submitter)

    @documents = add_completed_email_attachments!(submitter)

    @email_config = AccountConfigs.find_for_account(@current_account, AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY)

    subject =
      if @email_config
        ReplaceEmailVariables.call(@email_config.value['subject'], submitter:)
      else
        'Your document copy'
      end

    mail(from: from_address_for_submitter(submitter),
         to: to || @submitter.friendly_name,
         subject:)
  end

  private

  def add_completed_email_attachments!(submitter)
    documents = Submitters.select_attachments_for_download(submitter)

    total_size = 0
    audit_trail_data = nil

    if submitter.submission.audit_trail.present?
      audit_trail_data = submitter.submission.audit_trail.download

      total_size = audit_trail_data.size
    end

    documents.each do |attachment|
      total_size += attachment.byte_size

      break if total_size >= MAX_ATTACHMENTS_SIZE

      attachments[attachment.filename.to_s] = attachment.download
    end

    attachments[submitter.submission.audit_trail.filename.to_s] = audit_trail_data if audit_trail_data

    documents
  end

  def from_address_for_submitter(submitter)
    submitter.submission.created_by_user&.friendly_name || submitter.submission.template.author.friendly_name
  end
end
