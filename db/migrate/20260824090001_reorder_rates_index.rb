class ReorderRatesIndex < ActiveRecord::Migration[8.1]
  def change
    # Reads always go "currency + provider + date range", so provider must
    # come before on_date for the index to serve the range scan.
    remove_index :rates, column: %i[currency on_date provider], unique: true
    add_index :rates, %i[currency provider on_date], unique: true
  end
end
