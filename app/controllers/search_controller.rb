# Copyright (C) 2012-2025 Zammad Foundation, https://zammad-foundation.org/

class SearchController < ApplicationController
  prepend_before_action :authentication_check

  # GET|POST /api/v1/search
  # GET|POST /api/v1/search/:objects

  def search_generic
    # Initial search_result from the service
    service_search_result = search_result_from_service

    # Apply controller-level filtering if necessary
    if controller_should_filter_agent_search?
      apply_controller_level_agent_filters(service_search_result.result) # Modify in place
    end

    # Prepare assets (needs to be done *after* potential filtering if assets are derived from final objects)
    # For now, let's assume assets are based on the potentially filtered list.
    # If search_result.result was modified in place, this should be okay.
    # If not, we need to be careful. Let's re-evaluate asset creation based on the structure of service_search_result.
    # The service_search_result.result is a hash { ModelClass => { objects: [], total_count: X } }
    # We need to ensure the :objects array within this hash is what's filtered.

    final_result_data = service_search_result.result # This hash will be modified by apply_controller_level_agent_filters

    assets = final_result_data
             .values
             .select { |data| data[:objects].present? } # Ensure :objects key exists and is not empty
             .each_with_object({}) { |index_result, memo| ApplicationModel::CanAssets.reduce index_result[:objects], memo }

    result = if param_by_object?
               result_by_object(final_result_data) # Pass potentially modified data
             else
               result_flattened(final_result_data) # Pass potentially modified data
             end

    render json: {
      assets: assets,
      result: result,
    }
  end

  private

  def controller_should_filter_agent_search?
    is_user_organization_search_context_for_controller? &&
      current_user.permissions?('ticket.agent') &&
      !current_user.permissions?('admin.user') && # General admin check
      !current_user.permissions?('admin.organization') # Org admin check
    # Add more specific admin permission checks if needed, e.g. !User::Search.is_admin_for_search?(current_user)
    # For now, a general admin check might suffice or use specific ones like admin.user and admin.organization
  end

  def is_user_organization_search_context_for_controller?
    return false if params[:objects].blank?

    search_object_parts = params[:objects].split('-').map(&:downcase).sort
    search_object_parts == %w[organization user]
  end

  def apply_controller_level_agent_filters(search_data_hash)
    agent_organization_ids = current_user.all_organization_ids

    # Filter Organizations
    if search_data_hash.key?(Organization) && search_data_hash[Organization][:objects].present?
      original_org_objects = search_data_hash[Organization][:objects]
      filtered_org_objects = original_org_objects.select do |org|
        agent_organization_ids.include?(org.id)
      end
      search_data_hash[Organization][:objects] = filtered_org_objects
      search_data_hash[Organization][:total_count] = filtered_org_objects.size
    end

    # Filter Users
    if search_data_hash.key?(User) && search_data_hash[User][:objects].present?
      if agent_organization_ids.empty?
        search_data_hash[User][:objects] = []
        search_data_hash[User][:total_count] = 0
      else
        original_user_objects = search_data_hash[User][:objects]
        filtered_user_objects = original_user_objects.select do |user|
          (user.organization_id.present? && agent_organization_ids.include?(user.organization_id)) ||
            (user.organization_ids.present? && (agent_organization_ids & user.organization_ids).any?)
        end
        search_data_hash[User][:objects] = filtered_user_objects
        search_data_hash[User][:total_count] = filtered_user_objects.size
      end
    end
  end

  def result_by_object(data_hash) # Modified to accept data_hash
    data_hash.each_with_object({}) do |(model, metadata), memo|
      memo[model.to_app_model.to_s] = {
        object_ids:  metadata[:objects].pluck(:id), # Assumes :objects is an array of AR records
        total_count: metadata[:total_count]
      }
    end
  end

  def result_flattened(data_hash) # Modified to accept data_hash
    # This needs careful handling if objects are already filtered.
    # The original search_result.flattened relies on Service::Search::Result struct.
    # We need a similar way to flatten our potentially modified data_hash.
    flat_list = []
    data_hash.each_value do |metadata|
      metadata[:objects].each do |item| # Assumes :objects is an array of AR records
        flat_list << {
          type: item.class.to_app_model.to_s,
          id:   item.id
        }
      end
    end
    # TODO: Consider sorting if `search_result.flattened` had specific sorting.
    # For now, it's just a flat list of what remains.
    flat_list
  end

  def search_result_from_service # Renamed from search_result to avoid confusion
    @search_result ||= begin
      # get params
      query = params[:query].try(:permit!)&.to_h || params[:query]

      Service::Search
        .new(current_user:, query:, objects: search_result_objects, options: search_result_options)
        .execute
    end
  end

  def search_result_options
    {
      limit:                      params[:limit] || 10,
      ids:                        params[:ids],
      offset:                     params[:offset],
      sort_by:                    Array(params[:sort_by]).compact_blank.presence,
      order_by:                   Array(params[:order_by]).compact_blank.presence,
      with_total_count:           param_by_object?,
      original_search_objects_param: params[:objects], # Pass the original objects string
    }.compact
  end

  def param_by_object?
    @param_by_object ||= ActiveModel::Type::Boolean.new.cast(params[:by_object])
  end

  def search_result_objects
    objects = Models.searchable

    return objects if params[:objects].blank?

    given_objects = params[:objects].split('-').map(&:downcase)

    objects.select { |elem| given_objects.include? elem.to_app_model.to_s.downcase }
  end
end
