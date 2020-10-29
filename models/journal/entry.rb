class Journal::Entry < ActiveRecord::Base
  ENTRY_TYPE_NORMAL = "normal"
  ENTRY_TYPE_CERTIFICATE = "certificate"
  ENTRY_TYPE_OWNERSHIP_CHANGE = "ownership_change"
  ENTRY_TYPES = [ENTRY_TYPE_NORMAL, ENTRY_TYPE_CERTIFICATE, ENTRY_TYPE_OWNERSHIP_CHANGE]

  belongs_to :journal
  belongs_to :form, class_name: 'Journal::Form', autosave: true, dependent: :destroy
  belongs_to :initial_template, class_name: 'Journal::FormTemplate'
  belongs_to :location
  belongs_to :billing_record, class_name: 'Transactions::BillingRecord'
  belongs_to :customer
  belongs_to :appointment, class_name: 'Schedule::Appointment'
  belongs_to :locked_by, class_name: 'User'
  belongs_to :quotation, class_name: 'Transactions::Quotation'
  belongs_to :opened_for_editing_by, class_name: 'User'

  has_one    :user, through: :form
  has_one    :payment, through: :billing_record, class_name: 'Transactions::Payment'
  has_many   :excerpt_entries, class_name: 'Journal::ExcerptEntry', dependent: :destroy

  before_validation :set_entry_kind, on: :create
  before_validation :check_valid_rows_in_certificate_template
  before_validation :remove_empty_billing_record_when_locking_entry
  before_validation :create_billing_record_with_attributes, on: :create, if: lambda { |e| e.normal? }, unless: lambda { |e| e.migrated? }
  before_validation :set_or_update_item_row_prices,         on: :create, if: lambda { |e| e.normal? }
  validates :location_id, :customer_id, :entry_type, presence: true
  validates :entry_type, inclusion: {in: ENTRY_TYPES}
  validates :locked_at,      presence: true, if: lambda { |e| e.locked? }
  validates :locked_by,      presence: true, if: lambda { |e| e.locked? && (e.normal? || e.certificate?) }
  validates :billing_record, presence: true, if: lambda { |e| e.normal? && !e.saving_locked_entry_without_transactions }, unless: lambda { |e| e.migrated? }
  validate :customer_should_be_owner_of_animal
  validate :customer_should_be_able_create_journal_entry
  validate :customer_is_removed, on: :create

  before_destroy :remove_billing_record
  before_destroy :remove_unconfirmed_prescriptions

  attr_readonly :initial_template_id

  attr_accessor :saving_locked_entry_without_transactions
  delegate :paid?, to: :billing_record, allow_nil: true

  scope :locked,         -> { where(locked: true) }

  def ready_for_animal_health_data_export?
    animal_health_data_exported_at.nil? && export_animal_health_data?
  end

  def name
    (initial_template || quotation).try(:name)
  end

  def description
    (initial_template || quotation).try(:description)
  end

  # Returns billing record rows in same order as rows in entry.
  def billing_record_rows
    form.rows.map do |row|
      row.billing_record_rows
    end.flatten.compact
  end

  def migrated?
    title && title[/^Överflyttad/]
  end

  delegate :offline_rows=, to: :form

  def traffic_light_color
    if locked?
      if !billing_record.try(&:paid?)
        :red
      else
        :green
      end
    else
      :yellow
    end
  end

  def can_be_locked_by?(user)
    has_any_responsible_row?(user) || user_created_this?(user)
  end

  def responsible_from_form_rows
    form.rows.select(&:responsible)
  end

  def responsible
    responsible_from_form_rows.map(&:responsible).uniq
  end

  def responsible_without_user
    responsible.reject { |r| r == user }
  end

  def certificate?
    entry_type == ENTRY_TYPE_CERTIFICATE
  end

  def normal?
    entry_type == ENTRY_TYPE_NORMAL
  end

  def deletable?
    return false if locked?
    return false if contains_non_deletable_row?
    return false if contains_non_deletable_lab_sample?
    return false if contains_non_deletable_referral?
    true
  end

  def contains_non_deletable_row?
    form.rows.detect { |r| !r.deletable? }.present?
  end

  def contains_non_deletable_lab_sample?
    form.rows.detect { |r| r.contains_non_deletable_lab_sample? }.present?
  end

  def contains_non_deletable_referral?
    form.rows.detect { |r| r.contains_non_deletable_referral? }.present?
  end

  def self.non_deleted
    where("NOT deleted")
  end

  def form_with_initialize
    form_without_initialize or self.form = Journal::Form.new
  end

  alias_method_chain :form, :initialize

  def user=(user)
    self.form.user = user
  end

  def can_be_cancelled?
    locked? && !cancelled? && billing_record.try(&:refunded?)
  end

  def cancel!
    self.cancelled = true
    save!
  end

  def make_independent!
    old_user = self.form.user
    self.locked = false
    self.locked_at = nil
    self.locked_by_id = nil
    self.deleted = false
    self.cancelled = false
    self.form_id = nil
    self.billing_record_id = nil
    self.opened_for_editing_by_id = nil
    self.opened_for_editing_at = nil
    self.animal_health_data_exported_at = nil
    self.quotation_id = nil

    # Initialize the new clone
    self.save!
    self.form.user = old_user
    self
  end

  def deep_clone
    clone = self.dup.make_independent!

    # Clone the rows into the new form
    self.form.rows.each.with_index do |row, index|
      success, new_row = clone.form.insert_row_at_position(row.dup, index + 1)
      set_custom_validation_hints_for(new_row)
      billing_record_row = row.try(&:billing_record_row) if new_row.respond_to?(:billing_record_row)
      new_row.make_independent!({ entry: clone, billing_record_row: billing_record_row, original_row: row })
      # Journal::FormRow::ItemRow#update_price? will return tru on the new row so if the user has changed the price the price will
      # be changed to the original price.
      new_row.item_price = row.item_price if row.item_id == new_row.item_id
    end

    clone.save!
    clone
  end

  def preliminary_diagnoses
    form.diagnosis_rows.includes(:diagnosis).where("diagnosis_id IS NOT NULL AND preliminary = true").map(&:diagnosis)
  end

  def non_preliminary_diagnoses
    form.diagnosis_rows.includes(:diagnosis).where("diagnosis_id IS NOT NULL AND (preliminary = false OR preliminary IS NULL)").map(&:diagnosis)
  end

  def diagnoses
    form.diagnosis_rows.includes(:diagnosis).where("diagnosis_id IS NOT NULL").map(&:diagnosis).sort_by { |d| d.code }
  end

  def lock_and_save(user)
    success = false
    return success if locked?
    with_lock do
      self.locked = true
      self.locked_by = user
      self.locked_at = Time.now
      self.user = user unless user_created_this?(user)

      if has_valid_rows_for_locking? && save
        # Force reindexing of rows because the indexed document includes the fields entry.locked etc.
        form.rows.each(&:reindex)

        payment.salary_service.export_salary_events_when_locking_entry(self) if payment
        appointment.try(:finish!) if billing_record.blank? or billing_record.paid?
        appointment.try(:touch)

        success = true
      else
        # Note:
        #   Even if has_valid_rows_for_locking? returns false it still saves the current entry, therefor we
        #   need an explicit rollback
        raise ActiveRecord::Rollback
      end
    end
    success
  end

  # Used by journal excerpts generated by the filter method
  def entry_id
    @entry_id || id
  end

  def entry_id=(id)
    @entry_id = id
  end

  def appointment_id=(value)
    unless journal
      return super
    end

    new_appointment = Schedule::Appointment.find(value)
    owner = journal.owner

    if appointment and appointment != new_appointment
      appointment.animals.delete(owner)       if owner.kind_of? Animal
      appointment.herds.delete(owner)         if owner.kind_of? Animal::Herd
      appointment.animal_groups.delete(owner) if owner.kind_of? Animal::Group
      appointment.save!
    end

    new_appointment.animals       << journal.owner if owner.kind_of? Animal
    new_appointment.herds         << journal.owner if owner.kind_of? Animal::Herd
    new_appointment.animal_groups << journal.owner if owner.kind_of? Animal::Group

    super
  end

  def public_mission_items?
    item_rows.detect { |i| i.item && i.item.public_mission? }.present?
  end

  def lethal_items?
    item_rows.detect { |i| i.item.lethal? }.present?
  end

  def create_invitation_items?
    return true if initial_template and initial_template.create_invitation?
    item_rows.detect { |i| i.item.create_invitation? }.present?
  end

  def invitation_items
    item_rows.select { |i| i.item.create_invitation? }.map(&:name)
  end

  def active_model_serializer
    Offline::SyncDown::JournalEntrySerializer
  end

  def open_for_editing(user)
    if opened_for_editing_at.try(:>, 30.minutes.ago) and opened_for_editing_by.try(:!=, user)
      false
    else
      update(opened_for_editing_by: user, opened_for_editing_at: Time.now)
      true
    end
  end

  def close_for_editing
    update(opened_for_editing_at: nil, opened_for_editing_by: nil)
  end

  def export_animal_health_data?
    locked? && journal.owner.export_animal_health_data? && form.rows.any? {|r| r.kind_of?(Journal::FormRow::DiagnosisRow) }
  end

  def valid_item_rows
    item_rows.select { |ir| ir.item.present? && ir.billing_record_row }
  end

  def price_for_item(item)
    item = item_rows.detect { |row| row.item == item }
    item.amount_including_factors
  end

  def item_rows
    find_rows_of_type(Journal::FormRow::ItemRow)
  end

  def drug_rows
    find_rows_of_type(Journal::FormRow::DrugRow)
  end

  def image_rows
    find_rows_of_type(Journal::FormRow::ImageRow)
  end

  def prescription_rows
    find_rows_of_type(Journal::FormRow::PrescriptionRow)
  end

  def contains_referral?
    find_rows_of_type(Journal::FormRow::ReferralRow).any?
  end

  def contains_prescription?
    find_rows_of_type(Journal::FormRow::PrescriptionRow).any?
  end

  def contains_lab_sample?
    find_rows_of_type(Journal::FormRow::LabSampleRow).any?
  end

  def deleted_rows?
    form.rows.only_deleted.any?
  end

  private

  def set_custom_validation_hints_for(row)
    row.validate_drug_delivery = true if row.kind == 'drug'
    row.allow_inactive_items = true if row.kind_of? Journal::FormRow::ItemRow
    # billing_record_row will be nil here and may be created (in the case of drug-row with quantity=0) before
    # validation. This means that certain validations will fail. skip_validation_for_lock_and_save is therefor
    # checked in can_be_updated? on drug_row prior to checking skip_validation_for_lock_and_save on the billing
    # record row.
    row.billing_record_row.skip_validation_for_lock_and_save = true if row.respond_to?(:billing_record_row) && row.billing_record_row
    row.skip_validation_for_lock_and_save = true if row.respond_to?(:skip_validation_for_lock_and_save)
  end

  def has_valid_rows_for_locking?
    # workaround for Rails peculiarity. a row's entry would not be the same instance as self,
    # and therefore not have this instance's changed attributes (like #locked, #locked_at etc)
    form.rows.each { |r| r.form = self.form }
    form.entry = self

    # must loop over all rows to make sure not just the first row gets error messages populated
    validated_rows = form.rows.map do |row|
      set_custom_validation_hints_for(row)
      row.valid?
    end

    validated_rows.all?
  end

  def find_rows_of_type(klass)
    form.rows.grep(klass)
  end

  def has_any_responsible_row?(user)
    form.rows.detect { |row| row.responsible_id == user.id }.present?
  end

  def user_created_this?(user)
    self.user == user
  end

  def set_or_update_item_row_prices
    item_rows.each { |r| r.entry_on_build = self }
  end

  def create_billing_record_with_attributes
    # If appointment is tied to the journal entry, send in the start date which will be used to determine
    # what price factor revision value to use as per that date
    if appointment
      self.create_billing_record(transaction_date: Date.current, customer: customer, appointment_starts_at: appointment.starts_at)
    else
      self.create_billing_record(transaction_date: Date.current, customer: customer)
    end
  end

  def customer_should_be_able_create_journal_entry
    errors.add(:customer, "kan inte skapa journalanteckning. Kontrollera om kunden har en adress") unless customer and customer.can_create_journal_entry?
  end

  def customer_should_be_owner_of_animal
    unless journal.owner.has_owner?(customer)
      errors.add(:customer, 'är inte ägare till djuret')
    end
  end

  def remove_billing_record
    billing_record.destroy if billing_record
  end

  def remove_unconfirmed_prescriptions
    form.rows.with_deleted.grep(Journal::FormRow::PrescriptionRow).each do |row|
      if row.deletable?
        row.prescription.try(:destroy_items_for, journal.owner)
        row.destroy
      end
    end
  end

  def customer_is_removed
    if customer.try(:removed?)
      errors.add(:customer, 'kan inte vara inaktiv')
    end
  end

  def check_valid_rows_in_certificate_template
    if certificate?
      invalid_kinds = form.rows.flat_map(&:kind).reject { |k, _| Journal::FormRow.certificate_kinds.keys.include? k }
      if invalid_kinds.any?
        errors.add(:base, "Ett intyg kan inte innehålla " + invalid_kinds.map { |c| I18n.t(c, scope: "journal.form_row.kind").downcase }.join(', '))
      end
    end
  end

  def set_entry_kind
    if initial_template
      self.entry_type = ENTRY_TYPE_CERTIFICATE if initial_template.certificate?
      self.title = initial_template.name
    end
  end

  def remove_empty_billing_record_when_locking_entry
    if locked
      if billing_record && billing_record.rows.empty?
        self.billing_record = nil if billing_record.destroy
        @saving_locked_entry_without_transactions = true
      end
    end
  end
end
