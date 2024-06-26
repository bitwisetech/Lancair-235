# This is a model of the HONEYWELL BENDIX/KING KCS55/55a
# Pictorial Navigation System
#
# It is based on the corresponding manuals
# - Installation Manual 006-00111-0010, 10 February 2002
# - Pilots Guide KFC225 006-18035-0000, September 2004, Part KCS55A
# - Real life experience
#
#
# Copyright (C) 2008 Torsten Dreyer - Torsten (at) t3r _dot_ de
# The names HONEYWELL, BENDIX/KING are copyright of the owners
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# $Id: kcs55.nas,v 1.1 2009/09/26 19:03:26 helijah Exp $

var D2R = globals.D2R;
var R2D = globals.R2D;

var getLowPass = func( current, target, timeratio ) {

  if ( timeratio < 0.0 ) {
    if ( timeratio < -1.0 ) {
      #time went backwards; kill the filter
      current = target;
    } else {
      # ignore mildly negative time
    }
    return current;
  }
  if ( timeratio < 0.2 ) {
    # Normal mode of operation; fast
    #  approximation to exp(-timeratio)
    current = current * (1.0 - timeratio) + target * timeratio;
    return current;
  }

  if ( timeratio > 5.0 ) {
    # Huge time step; assume filter has settled
    current = target;
  } else {
    # Moderate time step; non linear response
    var keep = math.exp(-timeratio);
    current = current * keep + target * (1.0 - keep);
  }
  return current;
}

# The fluxgate
# based on mag_compass.cxx

# Input properties:
# /orientation/roll-deg
# /orientation/pitch-deg
# /orientation/heading-magnetic-deg
# /environment/magnetic-dip-deg
#
# Output properties:
# {base}/magnetic-heading-deg
#
var KMT112 = {
  new : func( baseNode, name = "kmt112", num = 0 ) {
    var obj = {};
    obj.parents = [KMT112];

    obj.rootNode = baseNode.getNode( name ~ "[" ~ num ~ "]", 1 );
    obj.magneticHeadingNode = obj.rootNode.initNode( "magnetic-heading-deg", 0.0 );

    obj._roll_node    = props.globals.getNode("/orientation/roll-deg", 1);
    obj._pitch_node   = props.globals.getNode("/orientation/pitch-deg", 1);
    obj._heading_node = props.globals.getNode("/orientation/heading-magnetic-deg", 1);
    obj._dip_node     = props.globals.getNode("/environment/magnetic-dip-deg", 1);

    return obj;
  },

  update : func( dt ) {
    # The flux gate (or flux valve) is - like the magnetic compass - prone
    # to the dip error but not to acceleration error.
    # This is the part of mag_compass.cxx that models the dip error

    var phi = me._roll_node.getValue() * D2R;
    var theta = me._pitch_node.getValue() * D2R;
    var psi = me._heading_node.getValue() * D2R;
    var mu = me._dip_node.getValue() * D2R;

    # these are expensive: don't repeat
    var sin_phi = math.sin(phi);
    var sin_theta = math.sin(theta);
    var sin_mu = math.sin(mu);
    var cos_theta = math.cos(theta);
    var cos_psi = math.cos(psi);
    var cos_mu = math.cos(mu);

    var a = math.cos(phi) * math.sin(psi) * cos_mu
          - sin_phi * cos_theta * sin_mu
          - sin_phi* sin_theta * cos_mu * cos_psi;

    var b = cos_theta * cos_psi * math.cos(mu)
          - sin_theta * sin_mu;

#   var newMagHeading = geo.normdeg(math.atan2(a,b)*R2D);
    var newMagHeading = me._heading_node.getValue();
    me.magneticHeadingNode.setDoubleValue( getLowPass( me.magneticHeadingNode.getValue(), newMagHeading, dt*4 ) );
  },
};

# The gyro
#
# Input properties:
# /position/latitude-deg
# {base}/input-power-node
# {base}/input-power-min
# {base}/input-power-max
# {base}/serviceable
# {base}/spin-decay-percentage
# {base}/fast-correction-rate-degps
# {base}/slow-correction-rate-degps
# ki525.slavingErrorNode
#
# Output properties:
# {base}/indicated-heading-deg
# {base}/spin-norm
# {base}/serviceable
# {base}/slaving-meter-norm

var KG102 = {
  new : func( baseNode, name = "kg102", num = 0 ) {
    var obj = {};
    obj.parents = [KG102];

    obj.rootNode = baseNode.getNode( name ~ "[" ~ num ~ "]", 1 );
    var inputPowerNodeNameNode = obj.rootNode.getNode( "input-power-node" );
    obj.inputPowerNode = nil;
    if( inputPowerNodeNameNode != nil ) {
      obj.inputPowerNode = props.globals.initNode( inputPowerNodeNameNode.getValue(), 0.0 );
    }
    obj.inputPowerMinNode = obj.rootNode.getNode( "input-power-min" );
    obj.inputPowerMaxNode = obj.rootNode.getNode( "input-power-max" );

    obj.positionLatitude = props.globals.getNode( "/position/latitude-deg", 1 );
    obj.trueHeadingNode = props.globals.getNode( "/orientation/heading-deg", 1 );

    obj.gyroHeadingNode = obj.rootNode.initNode( "indicated-heading-deg", 0.0 );
    obj.spinNode = obj.rootNode.initNode( "spin-norm", 0 );
    obj.serviceableNode = obj.rootNode.initNode( "serviceable", 1, "BOOL" );
    obj.spinDecayPercentageNode = obj.rootNode.initNode( "spin-decay-percentage", 0.005 );
    obj.slavingMeterNormNode = obj.rootNode.initNode( "slaving-meter-norm", 0.0 );
    obj.flagNode = obj.rootNode.initNode( "flag-norm", 0.0 );

    obj.lastTurn = 0.0;
    ## ab 3D06 obj.lastHeading = obj.trueHeadingNode.getValue();
    obj.lastHeading = obj.gyroHeadingNode.getValue();
    obj.offset = 0.0;

    var n = nil;
    var v = nil;

    obj.fastCorrectionRate = 3;
    n = obj.rootNode.getNode( "fast-correction-rate-degps", 0 );
    if( n != nil ) {
      v = n.getValue();
      if( v != nil ) {
        obj.fastCorrectionRate = v;
      }
    }

    obj.slowCorrectionRate = 0.05;
    n = obj.rootNode.getNode( "slow-correction-rate-degps", 0 );
    if( n != nil ) {
      v = n.getValue();
      if( v != nil ) {
        obj.slowCorrectionRate = v;
      }
    }

    aircraft.data.add( obj.gyroHeadingNode );

    return obj;
  },

  update : func( dt ) {
    var spin = 0;

    var flag = 0;

    if( me.serviceableNode.getValue() != 0 ) {
      #calculate the input power
      var powerNorm = 1.0;
      if( me.inputPowerNode != nil ) {
        var power = me.inputPowerNode.getValue();
        if( power != nil ) {
          var minPower = me.inputPowerMinNode.getValue();
          var maxPower = me.inputPowerMaxNode.getValue();
          powerNorm = 2*power/(maxPower+minPower);
          flag += power < minPower;
        }
      }

      # calculate the output power

      # calculate the gyro
      spin = me.spinNode.getValue();
      spin -= me.spinDecayPercentageNode.getValue() * dt;
      spin += 0.15 * powerNorm * dt;
      if( spin > powerNorm )
        spin = powerNorm;
      if( spin < 0 )
        spin = 0;

      # calculate the gyrocompass
      # time based precession, 360deg per day at the poles
      me.offset -= dt / 360 * math.sin(me.positionLatitude.getValue()*D2R);
      # add precession due to gyro age, motion, ...

      # get the turn angle against last heading and filter
      var heading = me.trueHeadingNode.getValue();
      var turn = geo.normdeg( heading - me.lastHeading + 180 ) - 180;
      turn = getLowPass( me.lastTurn, turn, 100*dt*spin*spin);
      me.lastTurn = turn;
      me.lastHeading = heading;
      

      # get the current heading of the gyro, apply the filtered turn
      heading = me.gyroHeadingNode.getValue();
      heading += turn;

      if( me.ka51.slavedNode.getValue() != 0 ) {
        # slaved mode, apply correction from the flux gate
        var slavingError = me.ki525.slavingErrorNode.getValue();
        var rate = 0.0;
        if( slavingError > 0.0 ) {
          rate = me.slowCorrectionRate;
        }
        if( slavingError < 0.0 ) {
          rate = -me.slowCorrectionRate;
        }
        if( slavingError > 3.0 ) {
          rate = me.fastCorrectionRate;
          flag += 1;
        }
        if( slavingError < -3.0 ) {
          rate = -me.fastCorrectionRate;
          flag += 1;
        }
        heading += rate * dt;

        # calculate the output for the slaving meter
        var slavingErrorNorm = slavingError / 3.0;
        if( slavingErrorNorm > 1.0 )
          slavingErrorNorm = 1.0;
        if( slavingErrorNorm < -1.0 )
          slavingErrorNorm = -1.0;
        me.slavingMeterNormNode.setDoubleValue( slavingErrorNorm );
      } else {
        # manual mode, apply setting of manual slave switch
        flag = 1;
        var manualSlave = me.ka51.manualSlaveNode.getValue();
        heading += manualSlave * me.fastCorrectionRate * dt;
      }
      me.gyroHeadingNode.setDoubleValue( geo.normdeg(heading) );
    }
    me.spinNode.setDoubleValue( spin );
    if( spin < 0.5 )
      flag += 1-2*spin;
    if( flag > 1.0 )
      flag = 1.0;
    if( flag < 0.0 )
      flag = 0.0;
    me.flagNode.setDoubleValue( flag );
  },
};

# The controller
#
# Output properties
# {base}/slaved
# {base}/direction
var KA51 = {
  new : func( baseNode, name = "ka51", num = 0 ) {
    var obj = {};
    obj.parents = [KA51];

    obj.rootNode = baseNode.getNode( name ~ "[" ~ num ~ "]", 1 );

    obj.slavedNode    = obj.rootNode.initNode( "slaved", 0, "BOOL" );
    obj.manualSlaveNode = obj.rootNode.initNode( "manual-slave", 0, "INT" );

    aircraft.data.add( obj.slavedNode );
    return obj;
  },

  update : func( dt ) {
  },
};

# The KI525 HSI Indicator
var KI525 = {
  new : func( baseNode, name = "ki525", num = 0 ) {
    var obj = {};
    obj.parents = [KI525];

    obj.rootNode = baseNode.getNode( name ~ "[" ~ num ~ "]", 1 );
    obj.slavingErrorNode = obj.rootNode.initNode( "slaving-error-deg", 0.0 );
    obj.courseNode  = obj.rootNode.initNode( "selected-course-deg", 0.0 );
    obj.headingNode  = obj.rootNode.initNode( "selected-heading-deg", 0.0 );
    obj.courseErrorNode  = obj.rootNode.initNode( "course-error-deg", 0.0 );
    obj.headingErrorNode  = obj.rootNode.initNode( "heading-error-deg", 0.0 );

    # these properties are fed into our system
    obj.rootNode.getNode( "cdi-deflection", 1 ).alias( obj.getReferencedProperty( "cdi-deflection-property" ) );
    obj.rootNode.getNode( "gs-deflection", 1 ).alias( obj.getReferencedProperty( "gs-deflection-property" ) );
    obj.rootNode.getNode( "to-flag", 1 ).alias( obj.getReferencedProperty( "to-flag-property" ) );
    obj.rootNode.getNode( "from-flag", 1 ).alias( obj.getReferencedProperty( "from-flag-property" ) );
    obj.rootNode.getNode( "nav-flag", 1 ).alias( obj.getReferencedProperty( "nav-flag-property" ) );

    # tell the world about these values
    obj.getReferencedProperty("selected-course-property").alias( obj.rootNode.getNode( "selected-course-deg" ), 1 );

    # we provide these to the autopilo
    obj.getReferencedProperty("course-error-property").alias( obj.rootNode.getNode( "course-error-deg" ), 1 );
    obj.getReferencedProperty("heading-error-property").alias( obj.rootNode.getNode( "heading-error-deg" ), 1 );

    aircraft.data.add(
      obj.courseNode,
      obj.headingNode
    );
    return obj;
  },

  
  getReferencedProperty : func( name ) {
    var n = me.rootNode.getNode( name );
    if( n == nil ) {
      print( "WARNING: ki525: property not defined: " ~ name );
      return nil;
    }
    var s = n.getValue();
    if( s == nil ) {
      print( "WARNING: ki525: property no value defined: " ~ name );
      return nil;
    }
    return props.globals.getNode( s, 1 );
  },

  update : func( dt ) {
    var gyroHeading = me.kg102.gyroHeadingNode.getValue();
    var v = me.kmt112.magneticHeadingNode.getValue();
    me.slavingErrorNode.setDoubleValue( geo.normdeg(v - gyroHeading + 180 )-180);

    # provide offset course-arrow % magnetic-heading
    v = me.courseNode.getValue() or 0;
    me.courseErrorNode.setDoubleValue( geo.normdeg(v - gyroHeading + 180 )-180);

    # provide offset heading-bug % magnetic-heading
    v = me.headingNode.getValue();
    me.headingErrorNode.setDoubleValue( geo.normdeg(v - gyroHeading + 180 )-180);
  }
};

var KCS55 = {
  new : func(name = "kcs55", num = 0) {

    var obj = {};
    obj.parents = [KCS55];

    obj.rootNode = props.globals.getNode( "/instrumentation/" ~ name ~ "[" ~ num ~ "]", 1 );
    obj.elapsedTimeSecNode = props.globals.getNode( "/sim/time/elapsed-sec" );

    obj.kmt112 = KMT112.new( obj.rootNode );
    obj.kg102  = KG102.new( obj.rootNode );
    obj.ka51   = KA51.new( obj.rootNode );
    obj.ki525  = KI525.new( obj.rootNode );

    obj.ka51.kg102 = obj.kg102;

    obj.kg102.ka51 = obj.ka51;
    obj.kg102.ki525 = obj.ki525;

    obj.ki525.kmt112 = obj.kmt112;
    obj.ki525.kg102  = obj.kg102;

    obj.lastRun = obj.elapsedTimeSecNode.getValue();
    obj.update(obj.lastRun);

    print( "KCS55 pictorial navigation system initialized" );
    return obj;
  },

  update : func {
    var dt = me.elapsedTimeSecNode.getValue() - me.lastRun;
    me.kmt112.update( dt );
    me.kg102.update( dt );
    me.ka51.update( dt );
    me.ki525.update( dt );
    me.lastRun = me.elapsedTimeSecNode.getValue();
    settimer( func { me.update() }, 0 );
  },
};

var  nav_sele_node = props.globals.getNode("/instrumentation/nav-source/selector", 1) ;

#  When nav-source/selector changes 0-1-2 Nav[0]-KNS80-GPS : route props from Nav1/KNS80/GPS to KI525 display
setlistener("/instrumentation/nav-source/selector", func(tNode) {
  var tIndx = tNode.getValue();
  # property pointers hold property names of sources from various nav instruments
  var sele_crse_pntr = props.globals.getNode("/instrumentation/kcs55/ki525/selected-course-property", 1);
  var  cdi_defl_pntr = props.globals.getNode("/instrumentation/kcs55/ki525/cdi-deflection-property", 1);
  var   gs_defl_pntr = props.globals.getNode("/instrumentation/kcs55/ki525/gs-deflection-property", 1);
  var   to_flag_pntr = props.globals.getNode("/instrumentation/kcs55/ki525/to-flag-property", 1);
  var from_flag_pntr = props.globals.getNode("/instrumentation/kcs55/ki525/from-flag-property", 1);
  var  nav_flag_pntr = props.globals.getNode("/instrumentation/kcs55/ki525/nav-flag-property", 1);
  #  Prop nodes of kcs55 input props fed indirectly via names in props above
  var sele_crse_prop = "/instrumentation/kcs55/ki525/selected-course-deg";
  var  cdi_defl_prop = "/instrumentation/kcs55/ki525/cdi-deflection";
  var   gs_defl_prop = "/instrumentation/kcs55/ki525/gs-deflection";
  var   to_flag_prop = "/instrumentation/kcs55/ki525/to-flag";
  var from_flag_prop = "/instrumentation/kcs55/ki525/from-flag";
  var  nav_flag_prop = "/instrumentation/kcs55/ki525/nav-flag";
  #  Change value in this prop node to an integer to select nav source for ki525 display
  var ki525_srce_prop = "/instrumentation/kcs55/ki525/nav-srce-index";
  # nav-srce/selector is 0-indexed: select 0  for Nav 1  
  ##
  var sele_crse_srce_node = '';
  var cdi_defl_srce_node = ''; 
  var gs_defl_srce_node = '';
  var to_flag_srce_node = ''; 
  var from_flag_srce_node = '';
  var nav_flag_srce_node = '';
  #
  setprop( "/instrumentation/kcs55/ki525/nav-srce-index", tIndx);
  if (tIndx == 2 ) {
    # GPS These prop settings have not been tested     
    sele_crse_srce_node = "/instrumentation/gps/nav/heading-deg";
    cdi_defl_srce_node  = "/instrumentation/gps/nav/heading-needle-deflection-norm";
    gs_defl_srce_node   = "/instrumentation/gps/nav/glideslope-deflection-norm";
    to_flag_srce_node   = "/instrumentation/gps/nav/to-flag";
    from_flag_srce_node = "/instrumentation/gps/nav/from-flag";
    nav_flag_srce_node  = "/instrumentation/gps/nav/nav-flag";
  } else if (tIndx == 1 ) {
    # NAV2
    #sele_crse_srce_node = "/instrumentation/kns80/nav/heading-deg";
    sele_crse_srce_node = "/instrumentation/nav[1]/radials/selected-deg";
    cdi_defl_srce_node  = "/instrumentation/kns80/nav/heading-needle-deflection-norm";
    gs_defl_srce_node   = "/instrumentation/kns80/nav/glideslope-deflection-norm";
    to_flag_srce_node   = "/instrumentation/kns80/nav/to-flag";
    from_flag_srce_node = "/instrumentation/kns80/nav/from-flag";
    nav_flag_srce_node  = "/instrumentation/kns80/nav/in-range";
  } else {
    # NAV1
    sele_crse_srce_node = "/instrumentation/nav[0]/radials/selected-deg";
    cdi_defl_srce_node  = "/instrumentation/nav[0]/heading-needle-deflection-norm";
    gs_defl_srce_node   = "/instrumentation/nav[0]/gs-needle-deflection-norm";
    to_flag_srce_node   = "/instrumentation/nav[0]/to-flag";
    from_flag_srce_node = "/instrumentation/nav[0]/from-flag";
    nav_flag_srce_node  = "/instrumentation/nav[0]/in-range";
  }
  # Write props for new alii according to selected nav step
  sele_crse_pntr.setValue(sele_crse_srce_node);
  cdi_defl_pntr.setValue(cdi_defl_srce_node);
  gs_defl_pntr.setValue(gs_defl_srce_node);
  to_flag_pntr.setValue(to_flag_srce_node);
  from_flag_pntr.setValue(from_flag_srce_node);
  nav_flag_pntr.setValue(nav_flag_srce_node);
  # Unalias any previous alias values
  # These props may become nil during unalias - alias, see line 362 
  props.globals.getNode(sele_crse_prop).unalias();
  props.globals.getNode(cdi_defl_prop).unalias();
  props.globals.getNode(gs_defl_prop).unalias();
  props.globals.getNode(to_flag_prop).unalias();
  props.globals.getNode(from_flag_prop).unalias();
  props.globals.getNode(nav_flag_prop).unalias();
  # Alias internal properties via prop name values in poiner properties   
  props.globals.getNode(sele_crse_prop).alias(sele_crse_pntr.getValue());
  props.globals.getNode(cdi_defl_prop).alias(cdi_defl_pntr.getValue());
  props.globals.getNode(gs_defl_prop).alias(gs_defl_pntr.getValue());
  props.globals.getNode(to_flag_prop).alias(to_flag_pntr.getValue());
  props.globals.getNode(from_flag_prop).alias(from_flag_pntr.getValue());
  props.globals.getNode(nav_flag_prop).alias(nav_flag_pntr.getValue());
}, 0, 0);
