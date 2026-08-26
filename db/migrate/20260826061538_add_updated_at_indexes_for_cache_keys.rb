# SeriesController and ForecastsController key their caches by the table's
# MAX(updated_at); without an index that is a sequential scan over the whole
# table on every request.
class AddUpdatedAtIndexesForCacheKeys < ActiveRecord::Migration[8.1]
  def change
    add_index :rates, :updated_at
    add_index :forecast_runs, :updated_at
  end
end
