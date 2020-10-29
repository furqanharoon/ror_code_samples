class Journal::ImageSketch < ActiveRecord::Base
  belongs_to :image
  has_many :journal_rows, class_name: 'Journal::FormRow::ImageRow', foreign_key: 'sketch_id'

  mount_uploader :file, EntryImageSketchUploader

  attr_accessible :file, :image_id

  validates :file, presence: true, integrity: true, processing: true # Carrierwave-supplied validations
  validates :file, file_size: { maximum: 10.megabytes.to_i }

  def active_model_serializer
    Offline::SyncDown::JournalImageSerializer
  end
end
