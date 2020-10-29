# Each entry in this table specifies how often a certain journal form template
# has been used for a certain animal kind. This is used to suggest journal templates
# to use based on animal kind.
class Journal::FormTemplateUsageFrequency < ActiveRecord::Base
  belongs_to :form_template, class_name: "Journal::FormTemplate"
  belongs_to :animal_kind, class_name: "Animal::Kind"

  # Job to recalculate the form template usage frequencies
  class RecalculateJob
    def self.perform
      TenantRoster.perform_scheduled_tenants(Scheduler.find_name_by_class(self)) do
        Journal::FormTemplateUsageFrequency.recalculate!
      end
    end
  end

  # Recalculates statistics for the most frequently used journal templates.
  def self.recalculate!
    update_frequencies!(calculate_frequencies(animal_frequencies, herd_frequencies))
  end

  private

  def self.animal_frequencies
    journal_frequencies(Animal)
  end

  def self.herd_frequencies
    journal_frequencies(Animal::Herd)
  end

  def self.journal_frequencies(owner_type)
    table_name = owner_type.table_name
    Journal::Entry.select("#{table_name}.kind_id, journal_entries.initial_template_id as template_id, count(journal_entries.id) as frequency").
      joins("INNER JOIN journal_form_templates ON journal_entries.initial_template_id=journal_form_templates.id").
      joins("INNER JOIN journals ON journal_entries.journal_id = journals.id").
      joins("INNER JOIN #{table_name} ON journals.owner_id = #{table_name}.id").
      group("#{table_name}.kind_id, journal_entries.initial_template_id").
      where("journal_form_templates.category <> ?", "partial").
      where("journals.owner_type = ?", owner_type.to_s).
      where("#{table_name}.kind_id IS NOT NULL")
  end

  def self.calculate_frequencies(*partial_calculations)
    by_kind_and_template = Hash.new {|h, k| h[k] = Hash.new(0) }
    partial_calculations.each do |partial_results|
      partial_results.each do |result|
        by_kind_and_template[result.kind_id][result.template_id] += result.frequency.to_i
      end
    end
    by_kind_and_template
  end

  def self.update_frequencies!(frequency_by_kind_and_template)
    Journal::FormTemplateUsageFrequency.transaction do
      Journal::FormTemplateUsageFrequency.delete_all
      frequency_by_kind_and_template.each do |kind_id, template_and_freq|
        template_and_freq.each do |template_id, freq|
          Journal::FormTemplateUsageFrequency.create! do |f|
            f.animal_kind_id = kind_id
            f.form_template_id = template_id
            f.frequency = freq
          end
        end
      end
    end
  end
end
