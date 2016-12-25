#!/usr/bin/ruby

require 'optparse'
require 'fileutils'

include FileUtils

base_port=15010
port_step=10
distance=2
sitl_base_path="px4dir"

wrk_dir = __dir__ + '/'

#options
all_model_names = ["iris", "iris_opt_flow"]
opts = { model: "iris", num: 1 }

op = OptionParser.new do |op|
  op.banner = "Usage: #{__FILE__} [options] [world_file]"

  op.on("-m MODEL", all_model_names, all_model_names.join(", ")) do |m|
    opts[:model] = m
  end

  op.on("-n NUM", Integer, "number of instances") do |n|
    opts[:num] = n
  end

  op.on("-h", "help") do
    puts op
    exit
  end
end
op.parse!

users_world_fname = ARGV[0]
if users_world_fname
  unless File.exist?(users_world_fname)
    puts op
    exit
  end

  str = File.read(users_world_fname)
  all_model_names.each { |m|
    uri = "<uri>model://#{m}</uri>"
    if str.include?(uri)
      opts[:model] = m
      opts[:num] = str.lines.grep(/.*#{uri}.*/).size

      break
    end
  }
end

model = opts[:model]

#Firmware
px4_fname="px4"
px4_dir="Firmware/build_posix_sitl_default/src/firmware/posix/"
rc_script="Firmware/posix-configs/SITL/init/rcS_gazebo_#{model}"

#sitl_gazebo
model_path = "sitl_gazebo/models/#{model}/#{model}.sdf"
world_path = "sitl_gazebo/worlds/#{model}.world"
world_fname="default.world"
model_incs = ""

#mavros
mavros_dir="mavros"

system("./kill_sitl.sh")
sleep 1

unless Dir.exist?(sitl_base_path)
  mkdir sitl_base_path
  cp px4_dir+px4_fname, sitl_base_path
end

opts[:num].times do |i|
  x=i*distance
  m_index=i
  m_num=i+1

  mav_port = base_port + m_index*port_step
  mav_port2 = mav_port + 1

  mav_oport = mav_port + 5
  mav_oport2 = mav_port + 6

  sim_port = mav_port + 9

  bridge_port = mav_port + 2000

  cd(sitl_base_path) {
    model_name="#{model}#{m_num}"
    mkdir_p model_name

    cd(model_name) {
      rc_file="rcS#{m_num}"

      unless File.exist?(rc_file)
        mkdir_p "rootfs/fs/microsd"
        mkdir_p "rootfs/eeprom"
        touch "rootfs/eeprom/parameters"

        cp wrk_dir+"Firmware/ROMFS/px4fmu_common/mixers/quad_w.main.mix", "./"

        #generate rc file
        rc1 ||= File.read(wrk_dir + rc_script)
        rc = rc1.sub('param set MAV_TYPE',"param set MAV_SYS_ID #{m_num}\nparam set MAV_TYPE")
        rc.sub!('../../../../ROMFS/px4fmu_common/mixers/','')
        rc.sub!(/sdlog2 start.*\n/,'')
        rc.sub!(/.*OPTICAL_FLOW_RAD.*\n/,'') if model=="iris"

        rc.sub!(/simulator start -s.*$/,"simulator start -s -u #{sim_port}")

        rc.gsub!("-u 14556","-u #{mav_port}")
        rc.sub!("mavlink start -u #{mav_port}","mavlink start -u #{mav_port} -o #{mav_oport}")

        rc.sub!("-u 14557","-u #{mav_port2}")
        rc.sub!("-o 14540","-o #{mav_oport2}")

        File.open(rc_file, 'w') { |out| out << rc }
      end

      #run px4
      pid = spawn("../"+px4_fname,"-d",rc_file, :out => "out.log", :err => "err.log")
      Process.detach(pid)
    }

    #generate model
    model_incs += "    <include>
      <uri>model://#{model}</uri>
      <pose>#{x} 0 0 0 0 0</pose>
      <name>#{model_name}</name>
      <mavlink_udp_port>#{sim_port}</mavlink_udp_port>
    </include>\n"
  }

  cd(mavros_dir) {
    sleep 1
    system("./roslaunch_num.sh", "#{m_num}", "#{mav_oport2}", "#{mav_port2}", "#{bridge_port}")
  }
end

#run gzserver
if users_world_fname
  cp users_world_fname, world_fname
else
  world_sdf = File.read(world_path)
  File.open(world_fname, 'w') do |out|
    out << world_sdf.sub!(/.*<include>.*\n.*<uri>model:\/\/iris.*<\/uri>.*\n.*<\/include>.*\n/, model_incs)
  end
end

system("./gazebo.sh", world_fname)
