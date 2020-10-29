# abstract class! subclass to implement specific form row-types.
# use .new_from_kind instead of .new
#
# all form-row subclasses should have corresponding partials in app/views/journal/form_rows/SUBCLASS_NAME/_{edit,show,form}.html.haml
#
class Journal::FormRow < ActiveRecord::Base
  include MigratedRecordOwner

  validates :type, inclusion: { in: lambda { |r| KIND_MAPPING.values.map(&:to_s) } }

  # Used by Thinking Spinx
  belongs_to :_ts_prescription, foreign_key: :prescription_id, class_name: "Asab::SendVetPrescription"
  belongs_to :_ts_diagnosis, foreign_key: :diagnosis_id, class_name: "Diagnosis"
  belongs_to :_ts_item, foreign_key: :item_id, class_name: "Item"
  belongs_to :_ts_image, foreign_key: :image_id, class_name: 'Journal::Image'
  belongs_to :_ts_document, foreign_key: :document_id, class_name: 'Journal::Document'
  belongs_to :responsible, class_name: 'User'
  belongs_to :form, class_name: "Journal::Form", foreign_key: "form_id"
  before_validation :can_be_updated?
  before_destroy :can_be_destroyed?, unless: lambda { skip_destroy_validation_for_remove_rows_in_range }

  attr_accessible :responsible_id, :position, :deleted_at, :session_id
  attr_accessor :skip_destroy_validation_for_remove_rows_in_range

  acts_as_paranoid

  audited except: [:delta, :form, :mandatory, :position]

  KIND_MAPPING = {
    'image'             => Journal::FormRow::ImageRow,
    'item'              => Journal::FormRow::ItemRow,
    'diagnosis'         => Journal::FormRow::DiagnosisRow,
    'document'          => Journal::FormRow::DocumentRow,
    'multiquestion'     => Journal::FormRow::MultipleChoiceQuestionRow,   # Flerval
    'freetext'          => Journal::FormRow::FreeTextRow,                 # Fritext
    'question'          => Journal::FormRow::QuestionRow,                 # Fråga
    'internal_sample'   => Journal::FormRow::InternalLabSampleRow,
    'multicheckbox'     => Journal::FormRow::MultipleCheckboxRow,
    'drug'              => Journal::FormRow::DrugRow,
    'include'           => Journal::FormRow::IncludeRow,
    'milksample_double' => Journal::FormRow::MilkSampleDoubleRow,         # Får/get/häst
    'milksample'        => Journal::FormRow::MilkSampleRow,               # Nöt
    'milksample_single' => Journal::FormRow::MilkSampleSingleRow,         # Övriga
    'sample'            => Journal::FormRow::LabSampleRow,
    'prescription'      => Journal::FormRow::PrescriptionRow,
    'referral'          => Journal::FormRow::ReferralRow,
    'heading'           => Journal::FormRow::HeadingRow
  }

  def diagnoses_belongs_to_me
    unless belongs_to_diagnosis?
      return {
        diagnoses: [],
        topographies: [],
        preliminaries: []
      }
    end
    diagnoses_ids = []
    topography_ids = []
    preliminaries = []
    rows = previous_rows.select { |row| row.belongs_to_diagnosis? || row.kind_of?(Journal::FormRow::DiagnosisRow) }
    diagnoses_rows = rows.reverse.map do |row|
      if row.kind_of?(Journal::FormRow::DiagnosisRow) && row.diagnosis_id
        diagnoses_ids << Diagnosis.find(row.diagnosis_id)
        topography_ids << Topography.find(row.topography_ids) if row.topography_ids
        preliminaries << row.preliminary?
      end
    end
    {
      diagnoses: diagnoses_ids,
      topographies: topography_ids,
      preliminaries: preliminaries
    }
  end

  def previous_rows
    form.rows.where("position < ?", self.position)
  end

  def belongs_to_diagnosis?
    # Only rows with billing record row can belong to diagnosis
    false
  end

  # Override in implementing classes that has billing record row(s).
  def billing_record_rows
    []
  end

  def accessible_attributes_without_position
    self.attributes.slice(*self.class.accessible_attributes.to_a).except("position")
  end

  def reindex
    update_attribute(:delta, true)
  end

  def new_row
    self.class.new.tap { |r| r.attributes = self.attributes.slice(*self.class.accessible_attributes.to_a) }
  end

  def treatment_header?
    false
  end

  def class_name
    self.class.to_s.underscore.gsub('/', '_').to_sym
  end

  def self.certificate_kinds
    KIND_MAPPING.select { |k, _| ["heading", "freetext", "question", "multiquestion", "image", "multicheckbox"].include? k }
  end

  def self.row_kinds_for_certificate
    ["image", "freetext"]
  end

  # used by the views to determine if an input field should be rendered as disabled which is the case for paid/direktreglerade billingrecords
  def disabled?
    return false
  end

  # used by journal entry to determine if a row containing a lab sample is deletable or not
  def contains_non_deletable_lab_sample?
    false
  end

  # used by journal entry to determine if a row containing a referral is deletable or not
  def contains_non_deletable_referral?
    false
  end

  def show_mandatory?
    Tenant.current.dv? && !['include'].include?(self.kind)
  end

  def duplicate
    new_form_row = self.dup
    new_form_row
  end

  def self.kinds
    KIND_MAPPING.keys
  end

  def self.custom_row_kinds(include_prescription)
    KIND_MAPPING.keys.reject { |k| ['include', 'multiquestion', 'multicheckbox', 'heading', 'question', 'internal_sample'].include?(k) || !include_prescription && k == 'prescription'  }
  end

  def self.new_from_kind(value)
    KIND_MAPPING[value].new
  end

  def kind
    KIND_MAPPING.invert[type.constantize]
  end

  def flatten(*)
    [self]
  end

  def fields_text
    raise NotImplementedError
  end

  def generate_placeholder
    self.placeholder_id = rand(1<<31)
  end

  def deletable?
    entry_locked? && !is_template? ? false : true
  end

  def has_responses?
    false
  end

  def entry_locked?
    form && form.entry_locked?
  end

  def is_template?
    form && form.is_template?
  end

  # Default: No operation
  def make_independent!(options)
    self
  end

  def row_history
    audits.where(action: [:update, :destroy]).reject { |record| record.audited_changes.empty? }.reverse.group_by { |a| a.comment.to_s + a.action }.map do |_, grouped_audits|
      audit = grouped_audits.first
      # #becomes is necessary to set. If the row is deleted Audit will set the class to Journal::FormRow
      [audit, audit.revision.becomes(self.class)]
    end
  end

  def show_history_button?
    (created_at != updated_at) && row_history.size > 1
  end

  def session_id=(value)
    self.audit_comment = value
  end

  private

  def can_be_updated?
    errors.blank?
  end

  def can_be_destroyed?
    errors.add(:base, "Det går inte att ta bort rader som är obligatoriska enligt mallen") if mandatory?
    errors.blank?
  end

end
