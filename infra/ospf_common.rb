
require 'ipaddr'

class Class
  def attr_checked(attribute, &validation)
    define_method "#{attribute}=" do |val|
      raise "Invalid attribute #{val.inspect}" unless validation.call(val)
      instance_variable_set("@#{attribute}", val)
    end
    define_method attribute do
      instance_variable_get "@#{attribute}"
    end
  end
  def attr_writer_delegate(*args)
    # p self
    args.each do |name|
      define_method "#{name}=" do |value|
        # p "in method..", self.class
        instance_variable_set("@#{name}", 
                self.class.const_get(name.to_s.to_camel.to_sym).new(value))
      end
    end
  end
end

class String
  
  def to_underscore
    gsub(/([A-Z]+|[A-Z][a-z])/) {|x| ' ' + x }.gsub(/[A-Z][a-z]+/) {|x| ' ' + x }.split.collect{|x| x.downcase}.join('_')
  end
  
  def to_camel
    split('_').collect {|x| x.capitalize}.join
  end
  
  def hexlify
    l,n,ls,s=0,0,[''],self.dup
    while s.size>0
      l = s.slice!(0,16)
      ls << format("0x%4.4x:  %s", n, l.unpack("n#{l.size/2}").collect { |x| format("%4.4x",x) }.join(' '))
      n+=1
    end
    if l.size%2 >0
      ns = if l.size>1 then 1 else 0 end
      ls.last << format("%s%2.2x",' '*ns,l[-1])
    end
    ls
  end
  
end

class Symbol
  def to_klass
    to_s.to_camel.to_sym
  end
  def to_setter
    (to_s + "=").to_sym
  end
end


class Object
  def to_shex(*args)
    self.respond_to?(:encode) ? self.encode(*args).unpack('H*')[0] : ""
  end
  def to_shex_len(len, *args)
    s = to_shex(*args)
    "#{s[0..len]}#{s.size>len ? '...' : ''}"
  end
  def to_shex4_len(len, *args)
    s = to_shex4(*args)
    "#{s[0..len]}#{s.size>len ? '...' : ''}"
  end
  def to_bitstring
    if self.respond_to?(:encode)
      self.enc.unpack('B*')[0]
    else
      ""
    end
  end
  def method_missing(method, *args, &block)
    # puts "COMMON method_missing: #{method}"
  
    if method.to_s =~ /^to_s(\d+)/
      to_s($1.to_i)
    else
      # p caller
      super
    end
  end
  def define_to_s
    if defined?($style)
      self.class.class_eval { eval("alias :to_s :to_s_#{$style}") }
    elsif respond_to?(:to_s_default)
      self.class.class_eval { alias :to_s :to_s_default }
    else
      puts "You're screwed!"
    end      
  end
end

class Time
  class << self
    def to_ts
      Time.now.strftime("%M:%S")
    end
  end
end

class IPAddr
  alias encode hton

  def self.create(arg)
    if arg.is_a?(String) and arg.is_packed?
      IPAddr.new_ntoh(arg)
    elsif arg.is_a?(Integer)
      IPAddr.new_ntoh([arg].pack('N'))
    elsif arg.is_a?(Array) and arg[0].is_a?(Fixnum)
      IPAddr.new_ntoh([arg].pack('C*'))
    elsif arg.is_a?(self)
      IPAddr.new
    else
      IPAddr.new(arg)
    end
  end

  def mlen
    @_jme_mlen_ ||= _mlen_
  end

  def +(i)
    [IPAddr.create(to_i + i).to_s, mlen].join("/")
  end
  def ^(i)
    @increment ||= _generate_network_inc_
    [IPAddr.create(to_i + @increment.call(i)).to_s, mlen].join("/")
  end

  def netmask
    if ipv4?
      [@mask_addr].pack('N').unpack('C4').collect { |x| x.to_s}.join('.')
    else
      i = @mask_addr
      arr=[]
      while i>0 
        arr <<  (i & 0xffff) and i >>= 16
      end
      arr.reverse.collect { |x| x.to_s(16) }.join(':')
    end
  end
  
  def to_s_net
    [to_s,mlen].join('/')
  end
    
  def IPAddr.to_ary(prefix)
    source_address,mlen = prefix.split('/')
    ip = IPAddr.new(prefix)
    network = ip.to_s
    [ip, source_address, mlen.to_i, network, ip.netmask]
  end

  private
  
  def _mlen_
    m = @mask_addr
    len =  ipv6? ? 128 : 32
    loop do
      break if m & 1 > 0
      m = m >> 1
      len += -1
    end
    len
  end

  def _generate_network_inc_
    max_len =  ipv4? ? 32 : 128
    Proc.new { |n| n*(2**(max_len - mlen)) }
  end
  


end


module OSPFv2
  module Common
    
    def ivar_to_klassname(ivar)
      ivar.to_s.to_camel.to_sym
    end
    
    def set(h)
      # p "\n\n\n#{self.class}: IN SET(): ivars; #{ivars.inspect} - h: #{h.inspect}:"
      for key in [ivars].flatten
        # p key
        if h.has_key?(key) and ! h[key].nil?
          # puts "  h has key #{key}"
          begin
            klassname = key.to_klass
            if self.class.const_defined?(klassname)
              # puts "    class #{klassname} exists! => set @#{key.to_s} = #{klassname}.new(#{h[key]})"
              instance_variable_set("@#{key.to_s}", self.class.const_get(klassname).new(h[key]))
            elsif OSPFv2.const_defined?(klassname)
              # puts "    class OSPFv2::#{klassname} exists! => set @#{key.to_s} = #{klassname}.new(#{h[key]})"
              instance_variable_set("@#{key.to_s}", OSPFv2.const_get(klassname).new(h[key]))
            # elsif OSPFv2::LSDB::const_defined?(klassname)
            #   # puts "    class OSPFv2::LSDB::#{klassname} exists! => set @#{key.to_s} = #{klassname}.new(#{h[key]})"
            #   instance_variable_set("@#{key.to_s}", OSPFv2::LSDB::const_get(klassname).new(h[key]))
            elsif self.respond_to?(key.to_setter)
              # puts "    self respond to #{key.to_setter} => self.__send__ #{key.to_setter}, #{h[key]}"
              self.send key.to_setter, h[key]
            #elsif  has an instance variable of that name ? 
            #or create ivar on the fly ?
            else
              # puts "    just set ivar: @#{key} = #{h[key]}"
              instance_variable_set("@#{key.to_s}", h[key])
            end
          rescue ArgumentError => e
            raise
            # 
            # #FIXME: attr_writer_delegate generate a NameError (in link_state_database)
            # p "WE HAVE A NAME ERROR: #{e.inspect}"
            # # instance_variable_set("@#{key.to_s}", h[key])
          ensure
            h.delete(key)
          end
        else
          # puts "did not find #{key} in #{h.inspect}"
        end
      end
    end

    def to_hash
      h = {}
      for key in [ivars].flatten
        ivar = instance_variable_get("@#{key.to_s}")
        if ivar.respond_to?(:to_hash)
          # p "#{key} respond to hash"
          # p ivar
          # p "#{key} --"
          # p ivar
          h.store(key,ivar.to_hash)
        elsif ivar.is_a?(Array)
          h.store(key, ivar.collect { |x| x.to_hash })
        else
          # p "#{key} don't respond to hast"
          # p ivar
          # p ivar.class
          # p "#{key} --"
          #FIXME: ivar.to_s ? ivar.value ? ivar.hash_value ? 
          h.store(key,ivar) unless ivar.nil?
        end
      end
      h
    end
  end

  module Common
   
    def ivars
      instance_variables.reject { |x| x =~ /^@_/ }.collect { |x| x[1..-1].to_sym }
    end
    
  end
  
end

load "../../test/ospfv2/infra/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
