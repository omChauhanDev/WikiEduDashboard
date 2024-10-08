# frozen_string_literal: true

require_dependency "#{Rails.root}/lib/word_count"

#= Pushes course data to Salesforce, either by creating a new record or updating an existing one
class PushCourseToSalesforce
  include SalesforceHelper
  attr_reader :result

  def initialize(course)
    return unless Features.wiki_ed?
    @course = course
    @salesforce_id = @course.flags[:salesforce_id]
    @client = Restforce.new(SalesforceCredentials.get)
    push
  end

  private

  def push
    if @salesforce_id
      update_salesforce_record
    else
      create_salesforce_record
    end
  end

  def create_salesforce_record
    # :create returns the Salesforce id of the new record
    @salesforce_id = @client.create!('Course__c', course_salesforce_fields)
    @course.flags[:salesforce_id] = @salesforce_id
    @course.save
    @result = @salesforce_id
  end

  def update_salesforce_record
    @result = @client.update!('Course__c', { Id: @salesforce_id }.merge(course_salesforce_fields))
  # When Salesforce API is unavailable, it returns an HTML response that causes
  # a parsing error. If the course got deleted from Salesforce, it will throw a NotFoundError.
  rescue Faraday::ParsingError, Restforce::NotFoundError => e
    Sentry.capture_exception e, extra: { course: @course.slug }
  end

  def course_salesforce_fields
    salesforce_fields = base_salesforce_fields
    salesforce_fields[:Course_Level__c] = @course.level if @course.level.present?
    salesforce_fields[:Course_Format__c] = @course.format if @course.format.present?
    if @course.withdrawn
      salesforce_fields[:Did_not_do_assignment__c] = true
      salesforce_fields[:Status__c] = 'Complete'
    end
    salesforce_fields.merge!(wikidata_fields)
    salesforce_fields
  end

  # rubocop:disable Metrics/MethodLength
  # rubocop:disable Metrics/AbcSize
  def base_salesforce_fields
    {
      Name: @course.title,
      Course_Page__c: @course.url,
      Course_End_Date__c: @course.end.strftime('%Y-%m-%d'),
      Course_Dashboard__c: "https://#{ENV['dashboard_url']}/courses/#{@course.slug}",
      Program__c: program_id(@course),
      Estimated_No_of_Participants__c: @course.expected_students,
      Articles_edited__c: @course.article_count,
      Total_edits__c: @course.revision_count,
      Words_added_in_thousands__c: words_added_in_thousands,
      Article_views__c: @course.view_sum,
      No_of_Commons_uploads__c: @course.uploads.count,
      Actual_No_of_Participants__c: @course.user_count,
      Assignment_Start_Date__c: @course.timeline_start.strftime('%Y-%m-%d'),
      Editing_in_sandboxes_assignment_date__c: assignment_date_for(editing_in_sandbox_block),
      Editing_in_sandboxes_due_date__c: due_date_for(editing_in_sandbox_block),
      Editing_in_mainspace_assignment_date__c: assignment_date_for(editing_in_mainspace_block),
      Editing_in_mainspace_due_date__c: due_date_for(editing_in_mainspace_block),
      Medical_or_Psychology_Articles__c: editing_medicine_or_psychology?,
      Group_work__c: group_work?,
      Interested_in_DYK_or_GA__c: interested_in_dyk_or_ga?,
      Content_Expert__c: content_expert,
      Stay_in_sandbox__c: @course.stay_in_sandbox?,
      No_sandboxes__c: @course.no_sandboxes?,
      Submitted_at__c: @course.submitted_at&.iso8601,
      Approved_at__c: @course.approved_at&.iso8601
    }
  end
  # rubocop:enable Metrics/MethodLength
  # rubocop:enable Metrics/AbcSize

  def wikidata_fields
    return {} unless wikidata_stats
    {
      Wikidata_items_created__c: wikidata_stats['items created'] || 0,
      Wikidata_claims_added_removed_or_edited__c: (wikidata_stats['claims created'] || 0) +
        (wikidata_stats['claims removed'] || 0) +
        (wikidata_stats['claims changed'] || 0),
      Wikidata_references_added__c: wikidata_stats['references added'] || 0
    }
  end

  def wikidata_stats
    @course.course_stat&.stats_hash&.[]('www.wikidata.org')
  end

  def words_added_in_thousands
    WordCount.from_characters(@course.character_sum).to_f / 1000
  end

  def editing_in_sandbox_block
    title_matcher = Regexp.union('Draft your article', 'Start drafting your')
    @sandbox_block ||= @course.find_block_by_title(title_matcher)
  end

  def editing_in_mainspace_block
    @mainspace_block ||= @course.find_block_by_title('Begin moving your work to Wikipedia')
  end

  def assignment_date_for(block)
    return unless block.present?
    block.calculated_date.strftime('%Y-%m-%d')
  end

  def due_date_for(block)
    return unless block.present?
    block.calculated_due_date.strftime('%Y-%m-%d')
  end

  MEDICINE_AND_PSYCHOLOGY_TAGS = %w[yes_medical_topics maybe_medical_topics].freeze
  def editing_medicine_or_psychology?
    (course_tags & MEDICINE_AND_PSYCHOLOGY_TAGS).any?
  end

  def group_work?
    course_tags.include? 'working_in_groups'
  end

  def interested_in_dyk_or_ga?
    course_tags.include? 'dyk_and_ga'
  end

  def course_tags
    @course_tags ||= @course.tags.pluck(:tag)
  end

  def content_expert_ids
    Setting.find_or_create_by(key: 'content_expert_salesforce_ids').value
  end

  def content_expert
    staff_content_expert = @course.staff.find do |staffer|
      content_expert_ids[staffer.username].present?
    end
    return if staff_content_expert.nil?
    content_expert_ids[staff_content_expert.username]
  end
end
