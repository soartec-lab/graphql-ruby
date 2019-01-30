# frozen_string_literal: true
module GraphQL
  class Schema
    class Member
      module HasArguments
        def self.included(cls)
          cls.extend(ArgumentClassAccessor)
          cls.include(ArgumentObjectLoader)
        end

        def self.extended(cls)
          cls.extend(ArgumentClassAccessor)
          cls.include(ArgumentObjectLoader)
        end

        # @see {GraphQL::Schema::Argument#initialize} for parameters
        # @return [GraphQL::Schema::Argument] An instance of {arguments_class}, created from `*args`
        def argument(*args, **kwargs, &block)
          kwargs[:owner] = self
          arg_defn = self.argument_class.new(*args, **kwargs, &block)
          add_argument(arg_defn)
        end

        def argument_with_loads(name, type, *rest, loads: nil, **kwargs)
          if loads
            name_as_string = name.to_s

            inferred_arg_name = case name_as_string
            when /_id$/
              name_as_string.sub(/_id$/, "").to_sym
            when /_ids$/
              name_as_string.sub(/_ids$/, "")
                .sub(/([^s])$/, "\\1s")
                .to_sym
            else
              name
            end

            kwargs[:as] ||= inferred_arg_name
          end

          yield(name, type, *rest, loads: loads, **kwargs)
        end

        # Register this argument with the class.
        # @param arg_defn [GraphQL::Schema::Argument]
        # @return [GraphQL::Schema::Argument]
        def add_argument(arg_defn)
          own_arguments[arg_defn.name] = arg_defn
          arg_defn
        end

        # @return [Hash<String => GraphQL::Schema::Argument] Arguments defined on this thing, keyed by name. Includes inherited definitions
        def arguments
          inherited_arguments = ((self.is_a?(Class) && superclass.respond_to?(:arguments)) ? superclass.arguments : nil)
          # Local definitions override inherited ones
          if inherited_arguments
            inherited_arguments.merge(own_arguments)
          else
            own_arguments
          end
        end

        # @param new_arg_class [Class] A class to use for building argument definitions
        def argument_class(new_arg_class = nil)
          self.class.argument_class(new_arg_class)
        end

        module ArgumentClassAccessor
          def argument_class(new_arg_class = nil)
            if new_arg_class
              @argument_class = new_arg_class
            else
              @argument_class || (superclass.respond_to?(:argument_class) ? superclass.argument_class : GraphQL::Schema::Argument)
            end
          end
        end

        module ArgumentObjectLoader
          class LoadApplicationObjectFailedError < GraphQL::ExecutionError
            # @return [GraphQL::Schema::Argument] the argument definition for the argument that was looked up
            attr_reader :argument
            # @return [String] The ID provided by the client
            attr_reader :id
            # @return [Object] The value found with this ID
            attr_reader :object
            def initialize(argument:, id:, object:)
              @id = id
              @argument = argument
              @object = object
              super("No object found for `#{argument.graphql_name}: #{id.inspect}`")
            end
          end

          # Look up the corresponding object for a provided ID.
          # By default, it uses Relay-style {Schema.object_from_id},
          # override this to find objects another way.
          #
          # @param type [Class, Module] A GraphQL type definition
          # @param id [String] A client-provided to look up
          # @param context [GraphQL::Query::Context] the current context
          def object_from_id(type, id, context)
            context.schema.object_from_id(id, context)
          end

          def load_application_object(argument, lookup_as_type, id)
            # See if any object can be found for this ID
            loaded_application_object = object_from_id(lookup_as_type, id, context)
            context.schema.after_lazy(loaded_application_object) do |application_object|
              begin
                if application_object.nil?
                  raise LoadApplicationObjectFailedError.new(argument: argument, id: id, object: application_object)
                end
                # Double-check that the located object is actually of this type
                # (Don't want to allow arbitrary access to objects this way)
                application_object_type = context.schema.resolve_type(lookup_as_type, application_object, context)
                possible_object_types = context.schema.possible_types(lookup_as_type)
                if !possible_object_types.include?(application_object_type)
                  raise LoadApplicationObjectFailedError.new(argument: argument, id: id, object: application_object)
                else
                  # This object was loaded successfully
                  # and resolved to the right type,
                  # now apply the `.authorized?` class method if there is one
                  if (class_based_type = application_object_type.metadata[:type_class])
                    context.schema.after_lazy(class_based_type.authorized?(application_object, context)) do |authed|
                      if authed
                        application_object
                      else
                        raise GraphQL::UnauthorizedError.new(
                          object: application_object,
                          type: class_based_type,
                          context: context,
                        )
                      end
                    end
                  else
                    application_object
                  end
                end
              rescue LoadApplicationObjectFailedError => err
                # pass it to a handler
                load_application_object_failed(err)
              end
            end
          end

          def load_application_object_failed(err)
            raise err
          end
        end

        def own_arguments
          @own_arguments ||= {}
        end
      end
    end
  end
end
