# Copyright (C) 2012-2025 Zammad Foundation, https://zammad-foundation.org/

class Organization
  module Search
    extend ActiveSupport::Concern

    include CanSearch

    # methods defined here are going to extend the class, not the instance of it
    class_methods do

      # Helper method to determine if the current user is an agent whose search should be restricted
      def should_restrict_agent_search?(current_user)
        # Not an agent? Then this specific agent restriction logic doesn't apply.
        return false if !current_user.permissions?('ticket.agent')
        # An admin for organizations? Then no restriction.
        return false if current_user.permissions?('admin.organization')

        # Now we know it's an agent without admin.organization permission.
        # Check if they belong to any organization that grants unrestricted search.
        is_member_of_privileged_org = current_user.all_organizations.exists?(grants_unrestricted_search_to_members: true)

        # If they are a member of a privileged org, do *not* restrict their search.
        # Otherwise (if they are not a member of any privileged org), *do* restrict their search.
        !is_member_of_privileged_org
      end

=begin

search organizations preferences

  result = Organization.search_preferences(user_model)

returns if user has permissions to search

  result = {
    prio: 1000,
    direct_search_index: true
  }

returns if user has no permissions to search

  result = false

=end

      def search_preferences(current_user)
        return false if !current_user.permissions?(['ticket.agent', 'ticket.customer', 'admin.organization'])

        {
          prio:                1500,
          direct_search_index: !customer_only?(current_user),
        }
      end

      def customer_only?(current_user)
        return true if current_user.permissions?('ticket.customer') && !current_user.permissions?(['admin.organization', 'ticket.agent'])

        false
      end

      def search_default_sort_by
        %w[active updated_at]
      end

      def search_default_order_by
        %w[desc desc]
      end

      def search_params_pre(params)
        return if !customer_only?(params[:current_user])

        params[:ids] = params[:current_user].all_organization_ids
      end

      def search_sql_extension(params)
        statement = all
        current_user = params[:current_user]

        if should_restrict_agent_search?(current_user)
          statement = statement.where(id: current_user.all_organization_ids)
        end

        statement
      end

      def search_query_extension(params)
        query_extension = {}
        current_user = params[:current_user]

        if should_restrict_agent_search?(current_user)
          organization_ids = current_user.all_organization_ids
          if organization_ids.present?
            query_extension['bool'] ||= {}
            query_extension['bool']['must'] ||= []
            query_extension['bool']['must'].push({ 'terms' => { 'id' => organization_ids } })
          else
            # If agent has no organizations, they should see nothing
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
