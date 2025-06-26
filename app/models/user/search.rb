# Copyright (C) 2012-2025 Zammad Foundation, https://zammad-foundation.org/

class User
  module Search
    extend ActiveSupport::Concern

    include CanSearch

    included do
      scope :search_sql_extension, lambda { |params|
        statement = all
        current_user = params[:current_user]

        if params[:role_ids]
          statement = statement.joins(:roles).where('roles.id' => params[:role_ids])
        end

        if params[:group_ids]
          user_ids = []
          params[:group_ids].each do |group_id, access|
            user_ids |= User.group_access(group_id.to_i, access).pluck(:id)
          end
          statement = if user_ids.present?
                        statement.where(id: user_ids)
                      else
                        statement.none
                      end
        end

        if current_user && User.should_restrict_agent_search?(current_user)
          agent_organization_ids = current_user.all_organization_ids
          if agent_organization_ids.present?
            # Users whose primary organization is one of the agent's organizations
            # OR users who are secondary members of one of the agent's organizations
            statement = statement
                        .left_joins(:organizations_users)
                        .where(
                          "users.organization_id IN (:org_ids) OR organizations_users.organization_id IN (:org_ids)",
                          org_ids: agent_organization_ids
                        ).distinct
          else
            # If agent has no organizations, they should see no users (except themselves, if applicable by other rules)
            # However, adhering to "users in their orgs", this means none if they have no orgs.
            statement = statement.none
          end
        end

        # Fixes #3755 - User with user_id 1 is show in admin interface (which should not)
        statement.where('users.id != 1')
      }
    end

    # methods defined here are going to extend the class, not the instance of it
    class_methods do

      # Helper method to determine if the current user is an agent whose search should be restricted
      def should_restrict_agent_search?(current_user)
        # Not an agent? Then this specific agent restriction logic doesn't apply.
        return false if !current_user.permissions?('ticket.agent')
        # An admin for users? Then no restriction.
        return false if current_user.permissions?('admin.user')

        # Now we know it's an agent without admin.user permission.
        # Check if they belong to any organization that grants unrestricted search.
        is_member_of_privileged_org = current_user.all_organizations.exists?(grants_unrestricted_search_to_members: true)

        # If they are a member of a privileged org, do *not* restrict their search.
        # Otherwise (if they are not a member of any privileged org), *do* restrict their search.
        !is_member_of_privileged_org
      end

=begin

search user preferences

  result = User.search_preferences(user_model)

returns if user has permissions to search

  result = {
    prio: 1000,
    direct_search_index: true
  }

returns if user has no permissions to search

  result = false

=end

      def search_preferences(current_user)
        return false if !current_user.permissions?(['ticket.agent', 'admin.user'])

        {
          prio:                2000,
          direct_search_index: true,
        }
      end

      def search_default_sort_by
        %w[active updated_at]
      end

      def search_default_order_by
        %w[desc desc]
      end

      def search_params_pre(params)
        return if params[:permissions].blank?

        params[:role_ids] ||= []
        params[:role_ids] |= Role.with_permissions(params[:permissions]).pluck(:id)
      end

      def search_query_extension(params)
        query_extension = {}
        current_user = params[:current_user]

        # Existing role_ids filter
        if params[:role_ids].present?
          query_extension['bool'] ||= {}
          query_extension['bool']['must'] ||= []
          if !params[:role_ids].is_a?(Array)
            params[:role_ids] = [params[:role_ids]]
          end
          access_condition = {
            'query_string' => { 'default_field' => 'role_ids', 'query' => "\"#{params[:role_ids].join('" OR "')}\"" }
          }
          query_extension['bool']['must'].push access_condition
        end

        # Existing group_ids filter
        if params[:group_ids].present?
          user_ids_from_groups = []
          params[:group_ids].each do |group_id, access|
            user_ids_from_groups |= User.group_access(group_id.to_i, access).pluck(:id)
          end

          if user_ids_from_groups.present?
            query_extension['bool'] ||= {}
            query_extension['bool']['must'] ||= []
            query_extension['bool']['must'].push({ 'terms' => { 'id' => user_ids_from_groups } }) # Changed from _id to id
          else
            # If group filter results in no users, ensure the query reflects this
            query_extension['bool'] ||= {}
            query_extension['bool']['must'] ||= []
            query_extension['bool']['must'].push({ 'match_none' => {} })
            return query_extension # No need to add further agent filters if already matching none
          end
        end

        # Agent-specific filter based on organization membership
        if current_user && User.should_restrict_agent_search?(current_user)
          agent_organization_ids = current_user.all_organization_ids
          if agent_organization_ids.present?
            agent_org_filter = {
              'bool' => {
                'should' => [
                  { 'terms' => { 'organization_id' => agent_organization_ids } }, # Primary organization
                  { 'terms' => { 'organization_ids' => agent_organization_ids } } # Secondary organizations (assuming 'organization_ids' field is indexed)
                ],
                'minimum_should_match' => 1
              }
            }
            query_extension['bool'] ||= {}
            query_extension['bool']['must'] ||= []
            query_extension['bool']['must'].push(agent_org_filter)
          else
            # If agent has no organizations, they should see no users
            query_extension['bool'] ||= {}
            query_extension['bool']['must'] ||= []
            query_extension['bool']['must'].push({ 'match_none' => {} })
          end
        end

        query_extension
      end
    end
  end
end
