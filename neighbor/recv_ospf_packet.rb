module OSPFv2
  class Neighbor
    
    def recv_hello(hello, from, port)
      @neighbor_ip = from
      @state.recv_hello self, hello, from
    rescue Exception => e
      debug "rescued #{e.inspect}"
    end

    def recv_link_state_request(ls_request, from, port)
      #TODO: check what address the LSU shoul be send to ? unicast ? AllDRouteres ? AllSpfRouters ?
      send ls_request.to_lsu(@ls_db, :area_id=> @aread_id, :router_id => @router_id), from 
    end
    
    def recv_link_state_update(ls_update, from, port)
      ls_ack = LinkStateAck.ack_ls_update ls_update, :area_id=> @area_id, :router_id=> @router_id
      send ls_ack, OSPFv2::AllDRouters #from
      unless @ls_req_list.empty?
        ls_update.each { |l| 
          if @ls_req_list.has_key?(l.key)
            debug "*** deleting #{l.key.inspect} from Ls Req List! ***"
            @ls_req_list.delete(l.key) 
          end
        }
        new_state Full.new, 'loading_done' if @ls_req_list.empty?
       end
      @ls_db.recv_link_state_update ls_update
    end
    
    def recv_link_state_ack(ls_ack, from, port)
      return unless @ls_db
      before = @ls_db.all_not_acked.size
      ls_ack.each { |lsa| @ls_db.ls_ack lsa }
      debug "*** number of lsa acked : #{before - @ls_db.all_not_acked.size} ***"
    end

    def recv_database_description(rcv_dd, *args)
      
      case state
      when :exstart
        
        if router_id.to_i > rcv_dd.router_id.to_i
          debug "*** #{rcv_dd.router_id} is slave ***"
          if rcv_dd.master? 
            debug "*** #{rcv_dd.router_id} claims mastership ***"
            # @last_dd_seqn = @dd.seqn
            send_dd DatabaseDescription.new( :router_id=> @router_id, :area_id=> @area_id, imms=>7),  true
          elsif rcv_dd.seqn == @last_dd_seqn
            negotiation_done
            @last_dd_seqn += 1
            if @ls_db
              @ls_db.recv_dd(rcv_dd, @ls_req_list)
              dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id, 
                                            :ls_db => @ls_db, :number_of_lsa=>60
            else
              dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id
            end
            dd.is_master
            @last_dd_seqn = dd.seqn = @last_dd_seqn
            send_dd dd, true
          else
            # just stay in ExStart ...
            debug "*** @last_dd_seqn=#{@last_dd_seqn}, rcv_dd.seqn=#{rcv_dd.seqn} "
          end
        else
          debug "*** #{rcv_dd.router_id} is master ***"
          if rcv_dd.imms == 0x7
            if @ls_db
              @ls_db.recv_dd(rcv_dd, @ls_req_list)
              dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id, :ls_db => @ls_db
            else
              dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id
              dd.imms = 0 # no more
            end
            @last_dd_seqn_rcv = dd.seqn = rcv_dd.seqn
            dd_rxmt_interval.cancel
            send_dd dd, true
            negotiation_done
          end
        end

      when :exchange

        @tot_dd ||=0
        if rcv_dd.init?
          new_state ExStart.new(self), 'Init' 

        elsif rcv_dd.master? 
          debug "*** #{rcv_dd.router_id} is master ***"

          if rcv_dd.seqn - @last_dd_seqn_rcv == 1
            @tot_dd += 1
            @last_dd_seqn_rcv = rcv_dd.seqn
            if @ls_db
              @ls_db.recv_dd(rcv_dd, @ls_req_list)
              @dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id, 
              :ls_db => @ls_db, :dd_sequence_number=>rcv_dd.seqn
            else
              @dd.dd_sequence_number= rcv_dd.seqn # ack back
              @dd.imms = 0 # no more
            end
            send_dd @dd, true
          elsif rcv_dd.seqn == @last_dd_seqn_rcv
            # use rxmt
          else
            @state.seq_number_mismatch(self)
          end

          unless  rcv_dd.more? || @dd.more?
            dd_rxmt_interval.cancel
            new_state Loading.new(self), 'exchange_done'
            new_state Full.new, 'no loading: req list is empty' if @ls_req_list.empty?
          end

        else
          debug "*** #{rcv_dd.router_id} is slave ***"

          if rcv_dd.seqn == @last_dd_seqn

            if ! @dd.more? && ! rcv_dd.more?
              dd_rxmt_interval.cancel
              new_state Loading.new(self), 'exchange_done'
              new_state Full.new, 'no loading: req list is empty' if @ls_req_list.empty?

            else

              debug "*** OK: @last_dd_seqn=#{@last_dd_seqn}, rcv_dd.seqn=#{rcv_dd.seqn} "

              @last_dd_seqn += 1
              if @ls_db
                @ls_db.recv_dd(rcv_dd, @ls_req_list)
                @dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id, 
                :ls_db => @ls_db, :number_of_lsa=>60
              else
                @dd.no_more
              end
              @dd.is_master
              @dd.seqn = @last_dd_seqn
              send_dd @dd, true
            end

          elsif @last_dd_seqn - rcv_dd.seqn == 1
            debug "*** RXMT SHOULD FIX THIS: @last_dd_seqn=#{@last_dd_seqn}, rcv_dd.seqn=#{rcv_dd.seqn} "
          else
            debug "*** SHOULD GO TO EXSTART: @last_dd_seqn=#{@last_dd_seqn}, rcv_dd.seqn=#{rcv_dd.seqn} "
            new_state Full.new, "SeqNumberMismatch"
          end
          
        end
        
      else
        debug "*** recv dd packet while in #{state} #{rcv_dd.imms}***"
        unless rcv_dd.imms == 0
          new_state ExStart.new(self), 'recv dd packet'
          debug "*** recv dd packet while in #{state} ***"
        end
      end
    end
    
  end

end
