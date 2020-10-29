class Journal::ExcerptEntry < ActiveRecord::Base
  belongs_to :excerpt, class_name: 'Journal::Excerpt'
  belongs_to :form, class_name: 'Journal::Form', autosave: true
  belongs_to :entry, class_name: 'Journal::Entry'

  after_destroy :destroy_excerpt

  def to_journal_entry
    entry.dup.tap { |je| je.entry_id, je.form, je.created_at = entry.id, form, entry.created_at }
  end

  private

  def destroy_excerpt
    if excerpt and excerpt.entries.count.zero?
      excerpt.destroy
    end
  end
end
