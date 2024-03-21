# frozen_string_literal: true

module Submissions
  module CreateFromSubmitters
    module_function

    def call(template:, user:, submissions_attrs:, source:, submitters_order:, mark_as_sent: false, params: {})
      preferences = Submitters.normalize_preferences(user.account, user, params)

      Array.wrap(submissions_attrs).map do |attrs|
        submission_preferences = Submitters.normalize_preferences(user.account, user, attrs)
        submission_preferences = preferences.merge(submission_preferences)

        set_submission_preferences = submission_preferences.slice('send_email', 'bcc_completed')
        set_submission_preferences['send_email'] = true if params['send_completed_email']

        submission = template.submissions.new(created_by_user: user, source:,
                                              account_id: user.account_id,
                                              preferences: set_submission_preferences,
                                              template_submitters: [], submitters_order:)

        maybe_set_template_fields(submission, attrs[:submitters])

        attrs[:submitters].each_with_index do |submitter_attrs, index|
          uuid = find_submitter_uuid(template, submitter_attrs, index)

          next if uuid.blank?
          next if submitter_attrs.slice('email', 'phone', 'name').compact_blank.blank?

          submission.template_submitters << template.submitters.find { |e| e['uuid'] == uuid }

          is_order_sent = submitters_order == 'random' || index.zero?

          build_submitter(submission:, attrs: submitter_attrs, uuid:,
                          is_order_sent:, mark_as_sent:, user:,
                          preferences: preferences.merge(submission_preferences))
        end

        submission.tap(&:save!)
      end
    end

    def maybe_set_template_fields(submission, submitters_attrs, default_submitter_uuid: nil)
      template_fields = (submission.template_fields || submission.template.fields).deep_dup

      submitters_attrs.each_with_index do |submitter_attrs, index|
        submitter_uuid = default_submitter_uuid || find_submitter_uuid(submission.template, submitter_attrs, index)

        process_readonly_fields_param(submitter_attrs[:readonly_fields], template_fields, submitter_uuid)
        process_field_values_param(submitter_attrs[:values], template_fields, submitter_uuid)

        process_fields_param(submitter_attrs[:fields], template_fields, submitter_uuid)
      end

      if template_fields != submission.template.fields
        submission.template_fields = template_fields
        submission.template_schema = submission.template.schema
      end

      submission
    end

    def process_readonly_fields_param(readonly_fields, template_fields, submitter_uuid)
      return if readonly_fields.blank?

      template_fields.each do |f|
        next if f['submitter_uuid'] != submitter_uuid ||
                (!f['name'].in?(readonly_fields) &&
                 !f['name'].to_s.downcase.in?(readonly_fields) &&
                 !f['name'].to_s.parameterize.underscore.in?(readonly_fields))

        f['readonly'] = true
      end
    end

    def process_field_values_param(values, template_fields, submitter_uuid)
      return if values.blank?

      template_fields.each do |f|
        next if f['type'].in?(%w[signature image initials file])
        next if f['submitter_uuid'] != submitter_uuid

        value = values[f['uuid']]

        next if value.blank?

        f['default_value'] = value
      end
    end

    def process_fields_param(fields, template_fields, submitter_uuid)
      return if fields.blank?

      template_fields.each do |f|
        next if f['submitter_uuid'] != submitter_uuid

        field_configs = fields.find do |e|
          e['name'].to_s.casecmp(f['name'].to_s).zero? || e['name'] == f['name'].to_s.parameterize.underscore
        end

        next if field_configs.blank?

        assign_field_attrs(f, field_configs)
      end
    end

    def assign_field_attrs(field, attrs)
      field['title'] = attrs['title'] if attrs['title'].present?
      field['description'] = attrs['description'] if attrs['description'].present?
      field['readonly'] = attrs['readonly'] if attrs.key?('readonly')
      field['required'] = attrs['required'] if attrs.key?('required')

      if attrs['default_value'].present? && !field['type'].in?(%w[signature image initials file])
        field['default_value'] = Submitters::NormalizeValues.normalize_value(field, attrs['default_value'])
      end

      return field if attrs['validation_pattern'].blank?

      field['validation'] = {
        'pattern' => attrs['validation_pattern'],
        'message' => attrs['invalid_message']
      }.compact_blank

      field
    end

    def find_submitter_uuid(template, attrs, index)
      uuid = attrs[:uuid].presence
      uuid ||= template.submitters.find { |e| e['name'].to_s.casecmp(attrs[:role].to_s).zero? }&.dig('uuid')

      if attrs[:role].present? && uuid.blank? && defined?(Rollbar)
        Rollbar.error("Role doesn't existng: #{attrs[:role]}, #{template.id}")
      end

      uuid || template.submitters[index]&.dig('uuid')
    end

    def build_submitter(submission:, attrs:, uuid:, is_order_sent:, mark_as_sent:, user:, preferences:)
      email = Submissions.normalize_email(attrs[:email])
      submitter_preferences = Submitters.normalize_preferences(submission.account, user, attrs)

      submission.submitters.new(
        email:,
        phone: attrs[:phone].to_s.gsub(/[^0-9+]/, ''),
        name: attrs[:name],
        external_id: attrs[:external_id].presence || attrs[:application_key],
        completed_at: attrs[:completed] ? Time.current : nil,
        sent_at: mark_as_sent && email.present? && is_order_sent ? Time.current : nil,
        values: attrs[:values] || {},
        metadata: attrs[:metadata] || {},
        preferences: preferences.merge(submitter_preferences)
                                .merge({ default_values: attrs[:values] }.compact_blank)
                                .except('bcc_completed'),
        uuid:
      )
    end
  end
end
