class Journal::Excerpt < ActiveRecord::Base
  include Searchable

  has_many   :entries, class_name: "Journal::ExcerptEntry", foreign_key: :excerpt_id, dependent: :destroy
  belongs_to :journal
  belongs_to :user
  belongs_to :customer

  validates :journal_id, :customer_id, presence: true
  validates :entries, presence: true

  audited except: [:delta]
  attr_accessor :referral_id

  searchkick callbacks: :async, batch_size: 10_000, language: 'swedish', special_characters: false, index_name: tenant_index_name, match: :word_start, searchable: [:journal_excerpt_name]

  def search_data
    {
      journal_excerpt_name: name,
      journal_excerpt_journal_id: journal_id,
    }
  end

  def lab_samples
    entries
      .includes(form: :rows)
      .flat_map { |e| e.form.rows }.grep(Journal::FormRow::LabSampleRow)
      .map(&:lab_sample)
      .compact
  end

  def to_journal_entries
    entries.map(&:to_journal_entry).sort_by(&:created_at).reverse
  end

  def entry_attributes=(entry_attrs)
    entry_attrs = entry_attrs.map { |e| entry_with_row_attrs(e) }.reject { |e| e[:rows].empty? }

    entry_attrs.each do |entry_attrs|
      create_from_entry_attributes(entry_attrs)
    end
  end

  def description
    "Journalutdrag#{" " + name if name.present?} för #{journal.owner.name} skapat #{I18n.l(created_at.to_date)}"
  end

  def self.set_row_validation(row, locked)
    row.allow_inactive_items = true if row.kind_of?(Journal::FormRow::ItemRow)
    row.billing_record_row_id = nil

    if locked
      row.allow_negative_quantities = true if row.kind_of?(Journal::FormRow::ItemRow)
    else
      row.validate_drug_delivery = true if row.kind_of?(Journal::FormRow::DrugRow)
    end

    if row.respond_to?(:billing_record_row)
      row.billing_record_row.skip_validation_for_lock_and_save = true if row.billing_record_row
      row.independent_mode = true if row.kind_of?(Journal::FormRow::ItemRow)
    end
  end

  private

  def create_from_entry_attributes(entry_attrs)
    entry = Journal::Entry.find(entry_attrs[:entry_id])

    form_rows = Journal::FormRow.where(id: entry_attrs[:rows]).map do |orginal_row|
      orginal_row.dup.tap do |row|
        self.class.set_row_validation(row, entry.locked?)
      end
    end

    form = Journal::Form.new(rows: form_rows, user: entry.user)
    entry = entries.build(entry: entry, form: form)
    entry.save
  end

  def entry_with_row_attrs(entry)
    relevant_rows = (entry[:rows] || []).select { |r| r[:excerpt] }

    {
      entry_id: entry[:entry_id],
      rows:     relevant_rows.map { |r| r[:id] }
    }
  end
end
