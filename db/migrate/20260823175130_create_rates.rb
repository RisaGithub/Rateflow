class CreateRates < ActiveRecord::Migration[8.1]
  def change
    create_table :rates do |t|
      t.string :currency, null: false
      t.date :on_date, null: false
      t.decimal :value, precision: 12, scale: 4, null: false
      t.string :provider, null: false
    end

    add_index :rates, [ :currency, :on_date, :provider ], unique: true
  end
end
