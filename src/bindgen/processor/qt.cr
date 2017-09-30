module Bindgen
  module Processor
    # Processor for `C++/Qt` specific behaviour.  This includes:
    # * Handle `Q_GADGET` types
    # * Adding signal connection methods
    # * Support for private signals
    class Qt < Base
      # Type of the result of a Qt-sinal connect call.
      CONNECTION_HANDLE_TYPE = Parser::Type.parse("QMetaObject::Connection")

      # We'll remove all member methods of this name.
      QGADGET_CHECKER = "qt_check_for_QGADGET_macro"

      # Defined by `Q_OBJECT`, and thus in every signal-emitting class.
      PRIVATE_SIGNAL = "QPrivateSignal"

      def visit_class(klass)
        # Filter Qt-specific annoyances out.
        klass.nodes.select! do |node|
          if node.is_a?(Graph::Method)
            if node.origin.member_method? && node.origin.name == QGADGET_CHECKER
              false # Remove qt_check_for_QGADGET_macro
            elsif node.origin.signal? && private_signal_argument(node.origin)
              false # Remove private signal emission method
            else
              true # Keep otherwise
            end
          else
            true # Always keep non-methods
          end
        end

        # Add signals, ignoring default argument values towards the emission
        # method.
        klass.origin.each_wrappable_method do |method|
          handle_signal(klass, method) if method.signal?
        end

        super # Proceed.
      end

      # Checks if *signal* is marked private through the private
      # `QPrivateSignal` struct.  We have to handle these differently:
      # 1. The signal emission method must be removed
      # 2. The signal connection method doesn't carry this argument
      private def private_signal_argument(signal : Parser::Method)
        private_struct = "#{signal.class_name}::#{PRIVATE_SIGNAL}"

        signal.arguments.index do |arg|
          arg.base_name == private_struct
        end
      end

      # Adds the `#on_X` connector method of signal *method* into its *parent*.
      private def handle_signal(parent, method : Parser::Method)
        public_signal = unprivate_signal(method)
        connector = add_connect_method(parent, public_signal)
        add_cpp_call(connector, public_signal)
      end

      # Builds a signal *method* without a private signal argument.
      private def unprivate_signal(method : Parser::Method)
        if idx = private_signal_argument(method)
          args = method.arguments.dup # Remove the private argument
          args.delete_at(idx)

          Parser::Method.build(
            name: method.name,
            class_name: method.class_name,
            return_type: method.return_type,
            arguments: args,
          )
        else
          method # Public signal
        end
      end

      private def add_cpp_call(connector, method)
        to_proc = CallBuilder::CppToCrystalProc.new(@db)
        call = CallBuilder::CppQobjectConnect.new(@db)
        wrapper = CallBuilder::CppWrapper.new(@db)

        proc = to_proc.build(method)
        connector.calls[Graph::Platform::Cpp] = wrapper.build(
          method: connector.origin,
          target: call.build(method, proc),
        )
      end

      # Adds the *signal* connection method to *parent*.
      private def add_connect_method(parent, signal)
        conn_method = signal_connect_binding_method(signal)

        Graph::Method.new(
          origin: conn_method,
          name: conn_method.name,
          parent: parent,
        )
      end

      # Builds the method(s) used to generate the binding to a Qt signals connect
      # method.
      private def signal_connect_binding_method(signal : Parser::Method)
        proc_type = Parser::Type.proc(Parser::Type::VOID, signal.arguments)
        proc_arg = Parser::Argument.new("_proc_", proc_type)

        Parser::Method.build(
          name: "CONNECT_#{signal.name}",
          class_name: signal.class_name,
          return_type: CONNECTION_HANDLE_TYPE,
          arguments: [ proc_arg ],
          crystal_name: "on_#{signal.crystal_name}"
        )
      end
    end
  end
end