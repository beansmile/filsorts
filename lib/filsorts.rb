# frozen_string_literal: true

require "filsorts/version"
require "active_support"
require "active_record"
require "grape"

module Filsorts
  module FilsortsConcern
    extend ActiveSupport::Concern

    class_methods do
      def sorts
        @sorts ||= resource_attributes.keys
      end

      def filters(filters)
        @filsorts_filters ||= (filters && formated_filters(filters)) || default_filters
      end

      def formated_filters(filters)
        formated_data = {}
        filters.each do |column_name, predicate|
          formated_data[column_name] = {
            type: type_of(column_name),
            predicates: predicate ? [predicate] : predicates_of(column_name)
          }
        end
        formated_data
      end

      # TODO: default_association_filters custom_ransack_filters
      def default_filters
        result = {}
        result.reverse_merge! custom_ransack_filters
        result.reverse_merge! default_association_filters
        result.reverse_merge! content_column_filters
        result
      end

      def default_association_filters
        if respond_to?(:reflect_on_all_associations)
          reflect_on_all_associations.reduce({}) do |memo, association|
            if association.macro == :belongs_to
              if association.options[:polymorphic]
                memo[association.foreign_type] = {
                  type: String,
                  predicates: [:eq],
                  human_attribute_name: human_attribute_name(association.name)
                }
              end

              memo[association.foreign_key] = {
                type: Integer,
                predicates: [:eq],
                human_attribute_name: human_attribute_name(association.name)
              }
            else
              memo["#{association.name}_id"] = {
                type: Integer,
                predicates: [:eq],
                human_attribute_name: human_attribute_name(association.name)
              }
            end

            memo
          end
        else
          {}
        end
      end

      def custom_ransack_filters
        if respond_to?(:_ransackers)
          _ransackers.keys.reduce({}) do |memo, k|
            memo[k.to_sym] =
              {
                type: type_of(k),
                predicates: predicates_of(k),
                human_attribute_name: human_attribute_name(k),
                values: values_of(k)
              }

            memo
          end
        else
          {}
        end
      end

      def resource_attributes
        @resource_attributes ||= default_attributes
      end

      def default_attributes
        columns.each_with_object({}) do |c, attrs|
          unless reject_col?(c)
            name = c.name.to_sym
            attrs[name] = (method_for_column(name) || name)
          end
        end
      # if table doesn't exist
      rescue ActiveRecord::StatementInvalid
        {}
      end

      def reject_col?(c)
        primary_col?(c) || sti_col?(c)
      end

      def primary_col?(c)
        c.name == primary_key
      end

      def sti_col?(c)
        c.name == inheritance_column
      end

      def content_column_filters
        resource_attributes.select { |key, value| key == value }.values.reject { |f| f =~ /(password)|(token)/ }.reduce({}) do |memo, f|
          memo[f] = {
            type: type_of(f),
            predicates: predicates_of(f),
            human_attribute_name: human_attribute_name(f),
            values: values_of(f)
          }
          memo
        end
      end

      def method_for_column(c)
        respond_to?(:reflect_on_all_associations) && foreign_methods.has_key?(c) && foreign_methods[c].name.to_sym
      end

      def foreign_methods
        @foreign_methods ||= reflect_on_all_associations.
          select { |r| r.macro == :belongs_to }.
          reject { |r| r.chain.length > 2 && !r.options[:polymorphic] }.
          index_by { |r| r.foreign_key.to_sym }
      end

      def column_for(method)
        columns_hash[method.to_s] if respond_to? :columns_hash rescue nil # prohibit raise exception when excute rake task
      end

      def predicates_of(key)
        return [:eq] if defined_enums[key.to_s]

        type = column_for(key)&.type

        type = _ransackers[key.to_s].type if _ransackers[key.to_s]

        case type
        when :date, :datetime
          [:eq, :lt, :lteq, :gt, :gteq]
        when :string, :text
          [:cont, :eq, :start, :end]
        when :integer
          [:eq, :lt, :lteq, :gt, :gteq]
        when :float, :decimal
          [:eq, :lt, :lteq, :gt, :gteq]
        when :boolean
          [:eq]
        else
          []
        end
      end

      def type_of(key)
        return String if defined_enums[key.to_s]

        case column_for(key)&.type
        when :date
          Date
        when :datetime
          DateTime
        when :integer
          Integer
        when :float, :decimal
          Float
        else
          String
        end
      end

      def values_of(key)
        defined_enums[key.to_s]&.keys
      end
    end
  end
end

ActiveRecord::Base.class_eval do
  include Filsorts::FilsortsConcern
end

(Gem::Version.new(Grape::VERSION) >= Gem::Version.new('1.2') ? Grape::API::Instance : Grape::API).class_eval  do
  def self.filsorts_params(model, *args)
    options = args.extract_options!
    params do
      optional :q, type: Hash do
        model.filters(options[:filters]).each_pair do |k, v|
          v[:predicates].each do |predicate|
            if model.defined_enums[k.to_s] && !model._ransackers[k.to_s]
              model.ransacker k, formatter: ->(n) { model.public_send(k.to_s.pluralize)[n] }
            end

            optional "#{k}_#{predicate}", type: v[:type], desc: "#{v[:human_attribute_name]} #{I18n.t("ransack.predicates.#{predicate}")}", values: v[:values]
          end
        end
      end
      optional :sorts, type: String, values: model.sorts.map { |s| ["#{s} ASC", "#{s} DESC"] }.flatten
    end
  end
end

Grape::Endpoint.class_eval do
  def filsorts(resources)
    query = resources.ransack(params[:q])
    query.sorts = params[:sorts] if params[:sorts]
    query.result
  end
end
