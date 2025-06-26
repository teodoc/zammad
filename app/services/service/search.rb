# Copyright (C) 2012-2025 Zammad Foundation, https://zammad-foundation.org/

class Service::Search < Service::BaseWithCurrentUser
  Result = Struct.new(:result, :sorting) do
    def flattened
      result
        .in_order_of(:first, sorting)
        .flat_map { |elem| elem.last[:objects] }
    end
  end

  attr_reader :query, :objects, :options, :original_search_objects_param

  # @param current_user [User] which runs the search
  # @param query [String] to search for
  # @param objects [Array<ActiveRecord::Base>] searchable classes with search_preferences method present
  # @param options [Hash] options to forward to CanSearch and SearchIndexBackend. E.g. offset and limit.
  def initialize(current_user:, query:, objects:, options: {})
    super(current_user:)

    @query   = query
    @objects = objects
    # Store original_search_objects_param from options, remove it from options to prevent it being passed down further
    @original_search_objects_param = options.delete(:original_search_objects_param)
    @options = options
      .compact_blank
      .with_defaults(limit: 10) # limit can be overriden
      .merge!(with_total_count: true, full: true) # those options are mandatory; :only_total_count can still be passed and will override
  end

  def execute
    # Determine context once
    user_org_context = is_user_organization_search_context?

    result = models_sorted
      .index_with do |model|
        model_result = search_single_model(model)

        # Conditional filtering for Users in 'user-organization' context
        if model == User && user_org_context && User::Search.should_be_considered_for_restriction?(current_user)
          model_result = filter_user_results_for_agent(current_user, model_result)
        end
        model_result
      end
      .compact

    Result.new(result, models_sorted)
  end

  private

  def filter_user_results_for_agent(agent, user_search_result)
    return user_search_result if user_search_result.blank? || user_search_result[:objects].blank?

    agent_organization_ids = agent.all_organization_ids
    if agent_organization_ids.empty?
      return { objects: [], total_count: 0 } # Agent with no orgs sees no users in this context
    end

    filtered_objects = user_search_result[:objects].select do |user|
      (user.organization_id.present? && agent_organization_ids.include?(user.organization_id)) ||
        (user.organization_ids.present? && (agent_organization_ids & user.organization_ids).any?)
    end

    # Note: total_count will now reflect the count *after* this in-memory filtering.
    # This might differ from a total count from a direct DB query with all conditions.
    { objects: filtered_objects, total_count: filtered_objects.size }
  end

  def is_user_organization_search_context?
    return false if original_search_objects_param.blank?

    search_object_parts = original_search_objects_param.split('-').map(&:downcase).sort
    search_object_parts == %w[organization user]
  end

  def models
    @models ||= objects
      .index_with { |elem| elem.search_preferences(current_user) }
      .compact_blank
  end

  def models_sorted
    @models_sorted ||= models.keys.sort_by { |elem| models.dig(elem, :prio) }.reverse
  end

  def search_single_model(model)
    if !SearchIndexBackend.enabled? || !models.dig(model, :direct_search_index)
      return model.search(query:, current_user:, **options)
    end

    SearchIndexBackend
      .search_by_index(query, model.name, options)
      .tap do |result|
        next if result.blank?
        next if !result[:object_metadata] # in case of :only_total_count

        result[:objects] = model.where_ordered_ids(result[:object_metadata].pluck(:id))
      end
  end
end
