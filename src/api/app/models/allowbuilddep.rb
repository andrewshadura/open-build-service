class Allowbuilddep < ActiveRecord::Base
  belongs_to :project, foreign_key: :db_project_id, inverse_of: :allowbuilddeps
end
