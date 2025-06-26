class AddGrantsUnrestrictedSearchToOrganizations < ActiveRecord::Migration[7.0] # Or appropriate Rails version
  def change
    add_column :organizations, :grants_unrestricted_search_to_members, :boolean, default: false, null: false
  end
end
