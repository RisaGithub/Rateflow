class CreateRefreshChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :refresh_checks do |t|
      t.string :kind, null: false
      t.string :origin, null: false
      t.string :currency
      t.string :outcome, null: false
      t.string :detail

      # No updated_at on purpose: a check is written once and never changes.
      t.datetime :created_at, null: false
    end

    add_index :refresh_checks, %i[origin created_at]
    add_index :refresh_checks, :created_at
  end
end
