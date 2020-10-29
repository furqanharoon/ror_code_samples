class Journal::Document < ActiveRecord::Base
  has_many :journal_rows, class_name: 'Journal::FormRow::DocumentRow'

  mount_uploader :file, BasicDocumentUploader

  attr_accessible :file, :file_cache

  validates :file, presence: true, integrity: true, processing: true # Carrierwave-supplied validations
  validates :file, file_size: { maximum: 10.megabytes.to_i }
end
