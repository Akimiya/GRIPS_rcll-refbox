#include "delivery_station.h"
#include "mps_io_mapping.h"
#include <iostream>

namespace llsfrb {
#if 0
}
#endif
namespace modbus {
#if 0
}
#endif

DeliveryStation::DeliveryStation(std::string name) : Machine(name, Station::STATION_DELIVERY) { }
DeliveryStation::~DeliveryStation() {}

void DeliveryStation::deliver_product(int slot) {
  send_command(machine_type_ | Operation::OPERATION_DELIVER, slot);
}

void DeliveryStation::identify() {
  send_command(Command::COMMAND_SET_TYPE, StationType::STATION_TYPE_DS);
}

}
}
