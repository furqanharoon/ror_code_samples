# Main class for all forms built in the system. This includes journal entries and form templates.
#
# A single row can be used in many different versions and even many different forms.
#
class Journal::Form < ActiveRecord::Base
  has_one :entry,         class_name: "Journal::Entry"
  has_one :template,      class_name: "Journal::FormTemplate"
  has_one :excerpt_entry, class_name: "Journal::ExcerptEntry"
  belongs_to :user

  has_many :diagnosis_rows, class_name: "Journal::FormRow::DiagnosisRow"
  has_many :rows, -> { order(:position) }, class_name: "Journal::FormRow", autosave: true, dependent: :destroy, foreign_key: "form_id" do
    def flatten
      flat_map(&:flatten)
    end
  end

  LOCKED_ROW_TYPES = ["Journal::FormRow::ItemRow", "Journal::FormRow::LabSampleRow", "Journal::FormRow::DrugRow"]

  class PositionCanNotBeUpdated < StandardError; end
  class FromPosition < StandardError; end
  class ToPosition   < StandardError; end

  def section_with_row(row)
    sections.select { |section| section.include? row }
  end

  def rows_to_display
    # Can't send #with_deleted if we're filtering the journal, because #with_deleted is an AR-scope.
    # `self` will not have been persisted if we're filtering, we basically do `Form.new(rows: filtered_rows, entry: entry)`.
    (persisted? ? self.rows.with_deleted : self.rows).reject {|r| r.kind == "freetext" && r.value.blank? }
  end

  # Insert a new row at <position> and refresh all row positions.
  # Returns the row
  def create_form_row(kind, attributes, position)
    row = build_form_row(kind, attributes, position)
    row.save
    row
  end

  # Updates an existing row. NOTE: Do not update position, use #move_row_form
  # Returns the row
  def update_form_row(row_id, attributes)
    raise PositionCanNotBeUpdated, "Position can not be updated! Use #move_row_form" if attributes.with_indifferent_access.has_key?(:position)
    row = self.rows.find(row_id) # Can only update non-deleted rows (will not find destroyed)
    row.tap { |r| r.attributes = attributes.slice(*r.class.accessible_attributes.to_a.map(&:to_sym)) }
    row.save
    row
  end

  # Deletes a row belonging to the form with the given id
  # Returns success, row
  def delete_form_row(row_id, non_paranoid_delete=false)
    response = true
    row = self.rows.find(row_id) # Can only delete non-deleted rows (will not find destroyed)

    if non_paranoid_delete
      response = false unless increment_row_positions(all_rows_from_position(row.position), -1)
      response = false unless row.really_destroy!
    else
      response = false unless row.destroy
    end

    [response, row]
  end

  # Moves a row to <position> and refresh all row positions.
  # Returns false on failure, otherwise true
  def move_form_row(row_id, to)
    response = true
    row = self.rows.find(row_id) # Can only move non-deleted rows (will not find destroyed)
    from = row.position

    to = position_boundary_check_for_move(to)

    if to > from
      move_row_from = from + 1
      move_row_to   = to
      increment     = -1
    else
      move_row_from = to
      move_row_to   = from - 1
      increment     = 1
    end

    response = false unless increment_row_positions(all_rows_from_start_to_stop(move_row_from, move_row_to), increment)
    response = false unless row.update_attribute :position, to
    response
  end

  # Insert rows at position and updates row positions
  def insert_rows_at_position(new_rows, position)
    validated_position = position_boundary_check_for_create(position)
    response = true
    response = false unless increment_row_positions(all_rows_from_position(validated_position), new_rows.size)

    created_rows = new_rows.map.with_index do |row, index|
      new_row = row.new_row
      new_row.position = validated_position + index
      response = false unless self.rows << new_row
      response = false unless new_row.save
      new_row
    end

    [response, created_rows]
  end


  def insert_row_at_position(new_row, position)
    response, new_rows = insert_rows_at_position([new_row], position)
    [response, new_rows.first]
  end

  def offline_rows=(new_rows)
    association(:rows).target = new_rows
  end

  # Removes all rows in position [from, to]
  def remove_rows_in_range!(from, to)
    validated_from, validated_to = validate_from_to_positions!(from, to)
    response = true

    rows_to_destroy = all_rows_from_start_to_stop(validated_from, validated_to)
    rows_to_destroy.each do |row|
      next if row.destroyed?
      row.skip_destroy_validation_for_remove_rows_in_range = true
      row.destroy
    end

    response = false unless rows_to_destroy.all?(&:destroyed?)

    response
  end

  def fields_text
    self.rows.map(&:fields_text).join("\n")
  end

  def self.single_row(kind, params = {})
    form = new(params)
    form.build_form_row(kind, {}, 1)
    form
  end

  def build_form_row(kind, attributes, position)
    validated_position = position_boundary_check_for_create(position)
    new_row = Journal::FormRow.new_from_kind(kind).tap { |r| r.attributes = attributes.slice(*r.class.accessible_attributes.to_a.map(&:to_sym)) }
    increment_row_positions(all_rows_from_position(validated_position), 1)
    new_row.position = validated_position
    self.rows << new_row
    new_row
  end

  def duplicate_form_row(row_id)
    response = false
    new_row = nil
    row = self.rows.find(row_id) # Can only duplicate non-deleted rows (will not find destroyed)
    if can_duplicate_row_associated_with_billing_record?(row)
      duplicated_row = remove_undesired_references(row.duplicate)
      response, new_rows = insert_rows_at_position([duplicated_row], row.position + 1)
      new_row = new_rows.first if response
    end
    [response, new_row]
  end

  def entry_locked?
    self.entry.nil? ? false : self.entry.locked?
  end

  def is_template?
    self.entry.nil? && self.template.present? ? true : false
  end

  private

  def remove_undesired_references(row)
    row.referral_id    = nil
    row.placeholder_id = nil
    row.lab_sample_id  = nil
    row.position       = nil
    row
  end

  def sections
    selected_rows = []
    sections = 0

    self.rows.each_with_index do |row, i|
      sections += 1 if row.kind_of?(Journal::FormRow::HeadingRow)
      selected_rows[sections] ||= []
      selected_rows[sections] << row
    end

    selected_rows.compact
  end

  # Returns all rows from position up until the end of the journal.
  # Useful for incrementing row positions for all rows after the cursor.
  def all_rows_from_position(position)
    self.rows.with_deleted.sort_by(&:position)[position - 1, highest_position]
  end

  # Returns all rows from start up until stop position.
  # Helper method for #remove_rows_in_range to make it more readable.
  def all_rows_from_start_to_stop(start, stop)
    self.rows.with_deleted[start - 1, stop - start + 1]
  end

  # Updates :position of all rows supplied in one SQL update with no validations.
  # Needs to be called as soon as rows are added or removed from the form.
  #
  # Returns false if something goes wrong, otherwise true
  def increment_row_positions(rows_for_update, increment)
    response = true
    return response if rows_for_update.nil?

    rows_without_id = rows_for_update.select { |r| r.id.nil? }
    # Special case for quotations only (?)
    if rows_without_id.any?
      rows_without_id.each do |row|
        row.position += increment
      end
    else
      update_clause = increment >= 0 ? "position = position + #{increment}" : "position = position - #{increment.abs}"
      response = false unless Journal::FormRow.with_deleted.where(id: rows_for_update.map(&:id)).update_all(update_clause) # Need to update positions of deleted rows too
    end
    response
  end

  def highest_position
    self.rows.with_deleted.count
  end

  # Returns 1 <= position <= total_#_rows
  def position_boundary_check_for_move(position)
    if position <= 0
      1
    elsif position > highest_position
      highest_position
    else
      position
    end
  end

  # Returns 1 <= position <= total_#_rows + 1
  def position_boundary_check_for_create(position)
    if position <= 0
      1
    elsif position > highest_position
      highest_position + 1
    else
      position
    end
  end

  def can_duplicate_row_associated_with_billing_record?(row)
    not (entry && entry.billing_record && entry.billing_record.uneditable? && LOCKED_ROW_TYPES.include?(row.type))
  end

  def validate_from_to_positions!(from, to)
    raise FromPosition, "Must be present" unless from.present?
    raise ToPosition,   "Must be present" unless to.present?
    raise FromPosition, "Must be greater than zero" unless from.to_i > 0
    raise ToPosition,   "Must be greater than zero" unless to.to_i > 0
    raise FromPosition, "Must be less than or equal to the total number of rows in the form" unless from.to_i <= highest_position
    raise ToPosition,   "Must be less than or equal to the total number of rows in the form" unless to.to_i <= highest_position
    raise ToPosition,   "Must be greater than the given from position" unless from.to_i <= to.to_i

    [from.to_i, to.to_i]
  end
end
