#--
# Copyright 2010 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
# OSPFv2 is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# OSPFv2 is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with OSPFv2.  If not, see <http://www.gnu.org/licenses/>.
#++

module OSPFv2
  class Neighbor

    def recv_database_description(rcv_dd, *args)
      
      case state
      when :exstart
        
        if router_id.to_i > rcv_dd.router_id.to_i
          debug "*** #{rcv_dd.router_id} is slave ***"
          if rcv_dd.master? 
            debug "*** #{rcv_dd.router_id} claims mastership ***"
            @last_dd_seqn += 1
            dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id, :imms=>7, :dd_sequence_number=>@last_dd_seqn
            send_dd dd,  true
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
          # I, M and MS set; other bits of the byte (RFC 4811's R) are not
          # for us to refuse it on.
          if rcv_dd.imms & 0x7 == 0x7
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
              @dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id
              @dd.imms = 0 # no more
            end
            @dd.dd_sequence_number = rcv_dd.seqn
            send_dd @dd, true
            unless rcv_dd.more? || @dd.more?
              dd_rxmt_interval.cancel
              new_state Loading.new(self), 'exchange_done'
              new_state Full.new, 'no loading: req list is empty' if @ls_req_list.empty?
            end
          elsif rcv_dd.seqn == @last_dd_seqn_rcv
            # The master retransmitted: our answer was lost, send it again.
            send_packet @sent_dd, @neighbor_ip if @sent_dd
          else
            @state.seq_number_mismatch(self)
          end

        else
          debug "*** #{rcv_dd.router_id} is slave ***"

          if rcv_dd.seqn == @last_dd_seqn
            # Read the slave's headers before deciding the exchange is
            # over: its last DD (M bit clear) still carries LSA headers.
            @ls_db.recv_dd(rcv_dd, @ls_req_list) if @ls_db

            if ! @sent_dd.more? && ! rcv_dd.more?
              dd_rxmt_interval.cancel
              new_state Loading.new(self), 'exchange_done'
              new_state Full.new, 'no loading: req list is empty' if @ls_req_list.empty?

            else

              debug "*** OK: @last_dd_seqn=#{@last_dd_seqn}, rcv_dd.seqn=#{rcv_dd.seqn} "

              @last_dd_seqn += 1
              if @ls_db
                @dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id,
                :ls_db => @ls_db, :number_of_lsa=>60
              else
                @dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id
                @dd.no_more
              end
              @dd.is_master
              @dd.seqn = @last_dd_seqn
              send_dd @dd, true
            end

          elsif @last_dd_seqn - rcv_dd.seqn == 1
            debug "*** RXMT SHOULD FIX THIS: @last_dd_seqn=#{@last_dd_seqn}, rcv_dd.seqn=#{rcv_dd.seqn} "
          else
            debug "*** SeqNumberMismatch: @last_dd_seqn=#{@last_dd_seqn}, rcv_dd.seqn=#{rcv_dd.seqn} "
            new_state ExStart.new(self), "SeqNumberMismatch"
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
