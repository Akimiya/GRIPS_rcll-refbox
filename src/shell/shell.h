
/***************************************************************************
 *  shell.h - LLSF RefBox shell
 *
 *  Created: Fri Feb 15 10:12:50 2013
 *  Copyright  2013  Tim Niemueller [www.niemueller.de]
 ****************************************************************************/

/*  Redistribution and use in source and binary forms, with or without
 *  modification, are permitted provided that the following conditions
 *  are met:
 *
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in
 *   the documentation and/or other materials provided with the
 *   distribution.
 * - Neither the name of the authors nor the names of its contributors
 *   may be used to endorse or promote products derived from this
 *   software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef __LLSF_REFBOX_SHELL_SHELL_H_
#define __LLSF_REFBOX_SHELL_SHELL_H_

#include <boost/asio.hpp>
#include <boost/date_time.hpp>
#include <google/protobuf/message.h>

#include <logging/llsf_log_msgs/LogMessage.pb.h>

#include <map>
#include <vector>
#include <string>
#include <mutex>

class NCursesPanel;
class NCursesMenu;

namespace protobuf_comm {
  class ProtobufStreamClient;
}

namespace llsf_msgs {
  class MachineInfo;
  class PuckInfo;
  class GameInfo;
}

namespace llsfrb_shell {
#if 0 /* just to make Emacs auto-indent happy */
}
#endif


class LLSFRefBoxShellMachine;
class LLSFRefBoxShellRobot;
class LLSFRefBoxShellOrder;
class LLSFRefBoxShellPuck;

class LLSFRefBoxShell
{
 public:
  LLSFRefBoxShell();
  ~LLSFRefBoxShell();

  const char * error() const;

  int run();
  void refresh();

 private: // methods
  void start_timers();
  void handle_timer(const boost::system::error_code& error);
  void handle_blink_timer(const boost::system::error_code& error);
  void handle_attmsg_timer(const boost::system::error_code& error);
  void handle_reconnect_timer(const boost::system::error_code& error);
  void handle_signal(const boost::system::error_code& error, int signum);

  void dispatch_client_connected();
  void dispatch_client_disconnected(const boost::system::error_code &error);
  void dispatch_client_msg(uint16_t comp_id, uint16_t msg_type,
			   std::shared_ptr<google::protobuf::Message> msg);

  void client_connected();
  void client_disconnected(const boost::system::error_code &error);
  void client_msg(uint16_t comp_id, uint16_t msg_type,
		  std::shared_ptr<google::protobuf::Message> msg);

  void start_keyboard();
  void handle_keyboard(const boost::system::error_code& error);

  void set_game_state(std::string state);
  void set_game_phase(std::string phase);
  void set_puck_under_rfid(const std::string &machine_name, unsigned int puck_id);
  void set_loaded_with(const std::string &machine_name, unsigned int puck_id);
  void send_remove_puck(std::string &machine_name, unsigned int puck_id);
  void send_set_team(std::string &team_name);

  void log(llsf_log_msgs::LogMessage::LogLevel log_level,
	   long int ts_sec, long int ts_nsec,
	   const std::string &component, const std::string &message);

  void log(llsf_log_msgs::LogMessage::LogLevel log_level,
	   const std::string &component, const char *format, ...);

  void logf(const char *format, ...);

  void beep(int frequency, int duration_ms);

 private: // members
  bool        quit_;
  const char *error_;
  std::string s_state_;

  NCursesPanel *panel_;
  NCursesPanel *navbar_;

  NCursesPanel *rb_log_;

  NCursesPanel *p_orders_;
  NCursesPanel *p_attmsg_;
  NCursesPanel *p_state_;
  NCursesPanel *p_phase_;
  NCursesPanel *p_time_;
  NCursesPanel *p_points_;
  NCursesPanel *p_team_;

  std::string   s_cancel_;
  NCursesMenu  *m_state_;
  NCursesMenu  *m_phase_;

  std::vector<LLSFRefBoxShellRobot *> robots_;
  std::map<std::string, LLSFRefBoxShellMachine *> machines_;
  std::vector<LLSFRefBoxShellOrder *> orders_;
  std::vector<LLSFRefBoxShellPuck *> pucks_;

  boost::asio::io_service      io_service_;
  boost::asio::deadline_timer  timer_;
  boost::asio::deadline_timer  reconnect_timer_;
  bool                         try_reconnect_;
  boost::asio::deadline_timer  blink_timer_;
  boost::asio::deadline_timer  attmsg_timer_;
  bool                         attmsg_toggle_;
  std::mutex                   attmsg_mutex_;
  std::string                  attmsg_string_;
  bool                         attmsg_has_endtime_;
  boost::posix_time::ptime     attmsg_endtime_;

  boost::asio::posix::stream_descriptor *stdin_;

  protobuf_comm::ProtobufStreamClient *client;

  std::shared_ptr<llsf_msgs::MachineInfo> last_minfo_;
  std::shared_ptr<llsf_msgs::PuckInfo> last_pinfo_;
  std::shared_ptr<llsf_msgs::GameInfo> last_gameinfo_;

  bool beep_warning_shown_;
};


} // end of namespace llsfrb

#endif
