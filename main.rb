#!/usr/bin/env ruby

class String

   NAME = {
         :func => {
         '100000' => :add,
         '100010' => :sub,
         '100100' => :and,
         '100101' => :or
      },
         :opcode => {
         '100011' => :lw,
         '001000' => :addi,
         '001101' => :ori,
         '000100' => :beq
      }
   }

   def to_dec signed = false # Convert binary string to decimal number.
      num = 0
      negative = signed && self[0] == '1'
      each_char do |c|
         num = num * 2 + (c == '0' ? 0 : 1)
      end
      num -= 2**size if negative
      num
   end

   def to_name from # Convert binary string of func or opcode to instruction name.
      NAME[from][self]
   end
end

class Symbol

   CONTROL_SIGNALS = {
      :lw => '000101011',
      :beq => '001010000',
      :addi => '000100010',
      :ori => '011100010'
   }

   def to_css # Convert instruction name to control signals.
      CONTROL_SIGNALS[self]
   end
end

class Mips

   attr_accessor :registers, :memory, :cc, :raw_instructions, :ifs, :ids, :exs, :mems, :wbs

   def initialize output_file = $stdout
      @output_file = output_file
      @raw_instructions = []
      @cc = 0
      @registers = [0, 8, 7, 6, 3, 9, 5, 2, 7]
      @memory = [5, 5, 6, 8, 8]
      @ifs = IFs.new self
      @ids = IDs.new self
      @exs = EXs.new self
      @mems = MEMs.new self
      @wbs = WBs.new self
   end

   def push raw_instruction
      @raw_instructions << raw_instruction
   end

   def << raw_instruction
      push raw_instruction
   end

   def run
      loop do
         solve_hazards
         f = false
         f = @wbs.process || f
         f = @mems.process || f
         f = @exs.process || f
         f = @ids.process || f
         f = @ifs.process || f
         break unless f
         @cc += 1
         @output_file.puts to_s
      end
   end

   def solve_hazards
      if @ids.instruction.name == :beq && @ids.read_data_1 ^ @ids.read_data_2 == 0 # Control hazard.
            @ifs.instruction = '0' * 32
            @ifs.pc = @ids.pc + @ids.instruction.imm * 4
      end
      unless @mems.instruction.empty? || @mems.instruction.name == :beq # Data hazard solved by forwarding from MEM/WB to ID/EX.
         wr = @mems.instruction.type == :R ? @mems.instruction.rd : @mems.instruction.rt
         unless wr.zero?
            wv = @mems.instruction.name == :lw ? @mems.read_data : @mems.alu_out 
            @ids.read_data_1 = wv if wr == @ids.instruction.rs
            @ids.read_data_2 = wv if wr == @ids.instruction.rt
         end
      end
      unless @exs.instruction.empty? || @exs.instruction.name == :beq # Data hazard solved by forwarding from EX/MEM to ID/EX.
         wr = @exs.instruction.type == :R ? @exs.instruction.rd : @exs.instruction.rt
         unless wr.zero?
            wv = @exs.alu_out
            @ids.read_data_1 = wv if wr == @ids.instruction.rs
            @ids.read_data_2 = wv if wr == @ids.instruction.rt
         end
      end
      if @ids.instruction.name == :lw && (@ids.instruction.rt == @ifs.instruction[6, 5].to_dec || @ids.instruction.rt == @ifs.instruction[11, 5].to_dec) # Data hazard caused by load word and solved by delay.
         @ifs.instruction = '0' * 32
         @ifs.pc -= 4
      end
   end

   def to_s
      s = "CC #{cc}:\n\n" # Clock cycle.

      s << "Registers:\n" # Registers
      (0...3).each do |i|
         (0...3).each do |j|
            k = i * 3 + j
            s << "$#{k}: #{@registers[k]}\t"
         end
         s << "\n"
      end
      s << "\n"

      s << "Data memory:\n" # Memory
      (0...5).each do |i|
         s << "#{(i * 4).to_s.rjust(2, '0')}:\t#{@memory[i]}\n"
      end
      s << "\n"

      s << "IF/ID :\n" # IF/ID
      s << @ifs.to_s
      s << "\n"

      s << "ID/EX :\n" # ID/EX
      s << @ids.to_s
      s << "\n"

      s << "EX/MEM :\n" # EX/MEM
      s << @exs.to_s
      s << "\n"

      s << "MEM/WB :\n" # MEM/WB
      s << @mems.to_s
      s << '=' * 65
      s << "\n"
   end

   class IFs

      attr_accessor :pc, :instruction

      def initialize mips
         @mips = mips
         @pc = 0
         @instruction = '0' * 32
      end

      def process
         f = true
         if @mips.raw_instructions[@pc / 4].nil?
            @instruction = '0' * 32
            f = false
         else
            @instruction = @mips.raw_instructions[@pc / 4]
         end
         @pc += 4
         f
      end

      def to_s
         s = "PC\t\t#{@pc}\n"
         s << "Instruction\t#{@instruction}\n"
      end
   end

   class IDs

      attr_accessor :read_data_1, :read_data_2, :sign_ext, :instruction, :pc

      def initialize mips
         @mips = mips
         @read_data_1 = @read_data_2 = @sign_ext = 0
         @instruction = Instruction.new
      end
      
      def process
         @instruction = Instruction.new @mips.ifs.instruction
         @pc = @mips.ifs.pc
         if @instruction.empty?
            @read_data_1 = @read_data_2 = @sign_ext = 0
            false
         else
            @read_data_1 = @mips.registers[@instruction.rs]
            @read_data_2 = @mips.registers[@instruction.rt]
            @sign_ext = @instruction.imm
            true
         end
      end

      def to_s
         s = "ReadData1\t#{@read_data_1}\n"
         s << "ReadData2\t#{@read_data_2}\n"
         s << "sign_ext\t#{@sign_ext}\n"
         s << "Rs\t\t#{@instruction.rs}\n"
         s << "Rt\t\t#{@instruction.rt}\n"
         s << "Rd\t\t#{@instruction.rd}\n"
         s << "Control signals\t#{@instruction.control_signals}\n"
      end
   end

   class EXs
      
      attr_accessor :alu_out, :write_data, :rtrd, :instruction

      def initialize mips
         @mips = mips
         @alu_out = @write_data = @rt = 0
         @instruction = Instruction.new
      end

      def process
         @instruction = @mips.ids.instruction
         @rtrd = @instruction.type == :R ? ['Rd', @instruction.rd] : ['Rt', @instruction.rt]
         a = @mips.ids.read_data_1
         b = @mips.ids.read_data_2
         i = @instruction.imm 
         if @instruction.empty?
            @alu_out = @write_data = 0
            false
         else
            case @instruction.name
            when :add
               @alu_out = a + b
            when :sub, :beq
               @alu_out = a - b
            when :and
               @alu_out = a & b
            when :or
               @alu_out = a | b
            when :addi, :lw
               @alu_out = a + i
            when :ori
               @alu_out = a | i
            end
            @write_data = b
            true
         end
      end

      def to_s
         s = "ALUout\t\t#{@alu_out}\n"
         s << "WriteData\t#{@write_data}\n"
         s << "#{@rtrd[0]}\t\t#{@rtrd[1]}\n"
         s << "Control signals\t#{@instruction.control_signals[4, 5]}\n"
      end
   end

   class MEMs

      attr_accessor :read_data, :alu_out, :instruction

      def initialize mips
         @mips = mips
         @read_data = @alu_out = 0
         @instruction = Instruction.new
      end

      def process
         @instruction = @mips.exs.instruction
         @alu_out = @mips.exs.alu_out
         @read_data = @instruction.name == :lw ? @mips.memory[@alu_out / 4] : 0
         !@instruction.empty?
      end

      def to_s
         s = "ReadData\t#{@read_data}\n"
         s << "ALUout\t\t#{@alu_out}\n"
         s << "Control signals\t#{@instruction.control_signals[7, 2]}\n"
      end
   end

   class WBs

      def initialize mips
         @mips = mips
      end

      def process
         instruction = @mips.mems.instruction
         return false if instruction.empty?
         return true if instruction.name == :beq
         data = instruction.name == :lw ? @mips.mems.read_data : @mips.mems.alu_out
         case instruction.type
         when :R
            @mips.registers[instruction.rd] = data
         when :I
            @mips.registers[instruction.rt] = data
         end
         true
      end
   end

   class Instruction

      attr_accessor :raw, :type, :name, :rs, :rt, :rd, :imm, :control_signals

      def initialize raw = '0' * 32
         @raw = raw
         if raw.nil? || raw == '0' * 32
            @empty = true
            @rs = @rt = @rd = @imm = 0
            @control_signals = '0' * 9
         else
            @empty = false
            @type = raw.match(/^000000/) ? :R : :I
            if @type == :R
               @name = raw[26, 6].to_name :func
               @rd = raw[16, 5].to_dec
               @imm = 0
               @control_signals = '110000010'
            else
               @name = raw[0, 6].to_name :opcode
               @rd = 0
               @imm = raw[16, 16].to_dec true
               @control_signals = @name.to_css
            end
            @rs = raw[6, 5].to_dec
            @rt = raw[11, 5].to_dec
         end
      end

      def empty?
         @empty
      end
   end
end

test_cases = [
   ['General.txt', 'genResult.txt'],
   ['Datahazard.txt', 'dataResult.txt'],
   ['Lwhazard.txt', 'loadResult.txt'],
   ['Branchazard.txt', 'branchResult.txt']
]

test_cases.each do |input, output|
   input_file = File.new input
   mips = Mips.new File.new output, 'w'
   loop do
      instruction = input_file.gets
      break if instruction.nil?
      mips << instruction.chomp
   end
   mips.run
end
