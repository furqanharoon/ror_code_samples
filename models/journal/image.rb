class Journal::Image < ActiveRecord::Base
  has_many :journal_rows, class_name: 'Journal::FormRow::ImageRow'
  has_many :sketches, class_name: 'Journal::ImageSketch'
  belongs_to :library_image

  mount_uploader :file, EntryImageUploader

  attr_accessible :file, :file_cache

  before_validation :perhaps_use_library_image, on: :create
  validates :file, presence: true, integrity: true, processing: true # Carrierwave-supplied validations
  validates :file, file_size: { maximum: 10.megabytes.to_i }

  def active_model_serializer
    Offline::SyncDown::JournalImageSerializer
  end

  private

  # re-use already uploaded library image and copy the file
  def perhaps_use_library_image
    self.file = open(library_image.file.file) if library_image
  end


  def open(file, type="rb")
    filename, ext = file.filename.split(".")

    local_file = Tempfile.new([*filename, ".#{ext}"])
    local_file.binmode
    local_file.write(file.read)

    local_file
  end
end
