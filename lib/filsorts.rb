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
        filters = (filters && formated_filters(filters)) || {}

        if filters.empty?
          default_filters.reject { |f| f =~ /(password)|(token)/ }.each do |f|
            filters[f] ||= {
              type: type_of(f),
              predicates: predicates_of(f)
            }
          end
        end

        filters
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
        result = []
        # result.concat default_association_filters
        result.concat content_columns
        # result.concat custom_ransack_filters
        result
      end

      def resource_attributes
        @resource_attributes ||= default_attributes
      end

      def association_columns
        @association_columns ||= resource_attributes.select { |key, value| key != value }.values
      end

      def default_attributes
        columns.each_with_object({}) do |c, attrs|
          unless reject_col?(c)
            name = c.name.to_sym
            attrs[name] = (method_for_column(name) || name)
          end
        end
      end

      def reject_col?(c)
        primary_col?(c) || sti_col?(c) || counter_cache_col?(c)
      end

      def primary_col?(c)
        c.name == primary_key
      end

      def sti_col?(c)
        c.name == inheritance_column
      end

      def counter_cache_col?(c)
        c.name.end_with?('_count')
      end

      def content_columns
        @content_columns ||= resource_attributes.select { |key, value| key == value }.values
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
        columns_hash[method.to_s] if respond_to? :columns_hash
      end

      def predicates_of(key)
        case column_for(key)&.type
        when :date, :datetime
          [:eq, :lt, :lteq, :gt, :gteq]
        when :string, :text
          [:cont, :eq, :start, :end]
        when :integer, :float, :decimal
          [:eq, :lt, :lteq, :gt, :gteq]
        when :boolean
          [:eq]
        else
          []
        end
      end

      def type_of(key)
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
            optional "#{k}_#{predicate}", type: v[:type]
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
