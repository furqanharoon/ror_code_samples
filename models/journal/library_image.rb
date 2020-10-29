class Journal::LibraryImage < ActiveRecord::Base
  has_and_belongs_to_many :animal_kinds, join_table: 'journal_library_images_animal_kinds', class_name: 'Animal::Kind'
  has_and_belongs_to_many :locations, join_table: 'journal_library_images_locations'
  belongs_to :category, class_name: 'Journal::LibraryImage::Category'
  has_many :images
  
  mount_uploader :file, LibraryImageUploader
  
  attr_accessible :name, :category_id, :animal_kind_ids, :location_ids, :file, :file_cache, :remove_file
  
  validates :name, :category_id, presence: true
  validates :file, presence: true, integrity: true, processing: true # Carrierwave-supplied validations
  validates :file, file_size: { maximum: 10.megabytes.to_i }
  
end
