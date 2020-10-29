class Journal::FormTemplate < ActiveRecord::Base
  include Workflow

  CATEGORIES = %w(template partial all)

  belongs_to :form, class_name: 'Journal::Form', autosave: true, dependent: :destroy
  has_and_belongs_to_many :locations, join_table: "journal_form_template_locations"
  has_and_belongs_to_many :animal_kinds, join_table: "journal_form_templates_animal_kinds", class_name: 'Animal::Kind'
  has_and_belongs_to_many :visiting_reasons, join_table: "journal_form_template_visit_reasons", class_name: 'Schedule::VisitReason'

  belongs_to :edited_by, class_name: 'User', foreign_key: 'edit_by'
  belongs_to :owner, class_name: 'User'

  validates :name, presence: true
  validates_length_of :name, maximum: 64
  validates :journal_searchable, inclusion: { in: [true, false] }
  validates_length_of :document_header, maximum: 64
  validates :document_header, presence: true, if: :certificate?
  validates :category, inclusion: { in: CATEGORIES }
  validate :valid_form_row_kinds_for_certificate, if: :certificate?
  validate :valid_kind
  validate :must_have_either_all_animal_kinds_or_animal_kind_ids
  validate :must_have_either_all_locations_or_location_ids
  validate :must_have_either_all_visiting_reasons_or_visiting_reason_ids

  after_save :refresh_all_ancestors, if: lambda { refresh_ancestors }

  attr_accessor :refresh_ancestors

  audited except: [:as_json_cached, :delta], allow_mass_assignment: true
  attr_protected :audit_ids

  workflow_column :status

  workflow do
    state :edit do
      event :edit, transitions_to: :edit
      event :publish, transitions_to: :public
    end

    state :public do
      event :edit, transitions_to: :edit
      event :publish, transitions_to: :public
    end
  end


  # When template is published, it is time to refresh all templates that include this template
  def publish
    refresh_all_ancestors
    save!
  end

  def certificate?
    kind == 'animal_certificate'
  end

  def self.insertable
    where("category IN('partial', 'all')")
  end

  def self.for_certificates
    where(kind: 'animal_certificate')
  end

  def self.for_journal_entries
    where(kind: ['animal_journal'])
  end

  def self.for_herd_journal_entries
    where(kind: ['herd_journal'])
  end

  def self.for_animal_and_herd_journal_entries
    where(kind: ['animal_and_herd_journal'])
  end

  # Returns the appropriate selection for includable templates within a template. This depends on each specific template kind.
  # Rules:
  #  1. Animal Journal: Journal and "Both"
  #  2. Herd Journal: Herd and "Both"
  #  3. "Both": Only "Both"
  #  4. Certificate: Only Certificate
  #  ELSE: Old behaviour
  def self.collection_for_kind(kind)
    case kind
      when "animal_journal"
        self.collection_for_journal_entries
      when "herd_journal"
        self.collection_for_herd_journal_entries
      when "animal_and_herd_journal"
        self.for_animal_and_herd_journal_entries
      when "animal_certificate"
        self.for_certificates
      else
        self.for_journal_entries
    end.insertable
  end

  # Choices for select-dropdown in template edit-view when rendering include rows.
  #
  # Arguments:
  #
  # * include_row - Journal::FormRow::IncludeRow
  # * template_kind - String ("animal_journal", "animal_certificate", ...)
  def self.collection_for_include_template_select(include_row, template_kind)
    collection = collection_for_kind(template_kind)

    # if already have chosen a template
    if include_row.include_template and not collection.include?(include_row.include_template)
       collection << include_row.include_template
    end

    collection.order(:name)
  end

  # Returns templates that are valid for any of the given visit reasons.
  # If no visit reasons are specified, only templates valid for all
  # visit reasons will be returned.
  def self.for_visit_reasons(reasons=[])
    if reasons.empty?
      where("journal_form_templates.all_visiting_reasons = ?", true)
    else
      # We use a subquery instead of a LEFT JOIN and GROUP BY since a GROUP BY
      # would require all selected columns to be listed in the GROUP BY part,
      # and we do not know which columns the client will need.
      subquery = "select form_template_id from journal_form_template_visit_reasons as visit_reasons " +
                 "where visit_reasons.form_template_id = journal_form_templates.id AND "+
                 "visit_reasons.visit_reason_id IN (?)"
      where("journal_form_templates.all_visiting_reasons = ? OR EXISTS(#{subquery})", true, reasons)
    end
  end

  # Returns templates that are valid for the given location.
  def self.for_location(location_id)
    joins("LEFT JOIN journal_form_template_locations as locations on " +
          "journal_form_templates.id = locations.form_template_id").
    where("journal_form_templates.all_locations = ? OR locations.location_id = ?", true, location_id)
  end

  # Returns the 5 most frequently used templates for each animal kind as struct:
  # {id, template_id, animal_kind_id}
  def self.frequently_used
    partition = %{
      SELECT * FROM (
        SELECT id, row_number()
        OVER (PARTITION BY animal_kind_id ORDER BY id)
        AS rownum
        FROM journal_form_template_usage_frequencies
      ) tmp
      WHERE rownum < 6
    }
    ids = ActiveRecord::Base.connection.select_rows(partition).map(&:first)
    data = select('freq.id as freq_id, freq.form_template_id, freq.animal_kind_id').
           where("freq.id IN (?)", ids).
           joins("JOIN journal_form_template_usage_frequencies as freq on freq.form_template_id = journal_form_templates.id").
           order("freq.frequency DESC")

    data.map do |t|
      {id: t.freq_id, template_id: t.form_template_id, animal_kind_id: t.animal_kind_id}
    end
  end

  # Returns the most frequently used templates for the given animal kind.
  def self.frequently_used_for(animal_kind_id)
    joins("INNER JOIN journal_form_template_usage_frequencies as freq on freq.form_template_id = journal_form_templates.id").
    where("freq.animal_kind_id = ?", animal_kind_id).
    order("freq.frequency DESC")
  end

  def self.active_templates(location_id, animal_kind_ids, kinds, category_template_or_partial = 'template')
    where('status = ?', 'public').
    joins('LEFT OUTER JOIN journal_form_template_locations ls ON journal_form_templates.id = ls.form_template_id').
    where('ls.location_id = ? OR all_locations = TRUE', location_id).
    joins('LEFT OUTER JOIN journal_form_templates_animal_kinds aks ON journal_form_templates.id = aks.form_template_id').
    where('aks.kind_id IN(?) OR all_animal_kinds = TRUE', animal_kind_ids).
    joins('LEFT OUTER JOIN journal_form_template_visit_reasons vrs ON journal_form_templates.id = vrs.form_template_id').
    where('journal_form_templates.kind IN(?)', kinds).
    where('journal_form_templates.journal_searchable = TRUE').
    order(:id).
    uniq
  end

  def available_kinds_as_json
    available_kinds.map do |kind|
      { kind: kind, translated_kind: I18n.translate(kind, scope: "journal.form_row.kind") }
    end
  end

  def available_kinds
    if certificate?
      Journal::FormRow.certificate_kinds.keys
    else
      Journal::FormRow.kinds
    end
  end

  def self.unpublished
    where('status = ?', 'edit')
  end

  def self.public_templates
    where('status = ?', 'public')
  end

  def billable_rows
    ids = form.rows.select(:id, :type, :include_template_id).flatten.select { |r| [Journal::FormRow::DrugRow, Journal::FormRow::ItemRow, Journal::FormRow::InternalLabSampleRow].include?(r.class) }.map(&:id)
    Journal::FormRow.where(id: ids)
  end

  def set_edited_by(edit_by = nil)
    self.edited_by = edit_by
    self.edit_at = Time.now
    edit!
  end

  def form_with_initialize
    form_without_initialize or self.form = Journal::Form.new
  end

  alias_method_chain :form, :initialize

  def active_model_serializer
    Offline::SyncDown::JournalTemplateSerializer
  end

  def rows_with_included_rows
    rows = form.rows.flatten
    rows.flat_map do |row|
      if row.kind_of? Journal::FormRow::IncludeRow
        row.flatten
      else
        row
      end
    end
  end

  private

  def refresh_all_ancestors
    templates_that_use_this_template.each do |t|
      t.refresh_ancestors = true
      t.save!
    end
  end

  def templates_that_use_this_template
    if persisted?
      Journal::FormRow::IncludeRow.where(include_template_id: self.id).map { |row| row.form.template }
    else
      []
    end
  end

  def self.collection_for_journal_entries
    where(kind: ['animal_journal', 'animal_and_herd_journal'])
  end

  def self.collection_for_herd_journal_entries
    where(kind: ['herd_journal', 'animal_and_herd_journal'])
  end

  def valid_kind
    unless kind.in? %w{animal_journal animal_certificate herd_journal animal_and_herd_journal quotation}
      errors.add(:kind, 'måste vara en av animal_journal|herd_journal|animal_and_herd_journal|animal_certificate|quotation')
    end
  end

  def valid_form_row_kinds_for_certificate
    invalid_kinds = form.rows.flat_map(&:kind).reject { |k, _| Journal::FormRow.certificate_kinds.keys.include? k }

    if invalid_kinds.any?
      errors.add(:kind, "Ett intyg kan inte innehålla " + invalid_kinds.uniq.map { |kind| I18n.t(kind, scope: "journal.form_row.kind").downcase }.join(', '))
    end
  end

  def must_have_either_all_animal_kinds_or_animal_kind_ids
    unless (all_animal_kinds ^ animal_kinds.any?)
      errors[:animal_kinds] << "måste anges"
    end
  end

  def must_have_either_all_locations_or_location_ids
    unless (all_locations ^ locations.any?)
      errors[:locations] << "måste anges"
    end
  end

  def must_have_either_all_visiting_reasons_or_visiting_reason_ids
    unless (all_visiting_reasons ^ visiting_reasons.any?)
      errors[:visiting_reasons] << "måste anges"
    end
  end
end
