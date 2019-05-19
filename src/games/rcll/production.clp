
;---------------------------------------------------------------------------
;  production.clp - LLSF RefBox CLIPS production phase rules
;
;  Created: Thu Feb 07 19:31:12 2013
;  Copyright  2013  Tim Niemueller [www.niemueller.de]
;  Licensed under BSD license, cf. LICENSE file
;---------------------------------------------------------------------------

(defrule production-start
  (declare (salience ?*PRIORITY_HIGH*))
  ?gs <- (gamestate (phase PRODUCTION) (prev-phase ~PRODUCTION))
  =>
  (modify ?gs (prev-phase PRODUCTION) (game-time 0.0))

  ; trigger machine info burst period
  (do-for-fact ((?sf signal)) (eq ?sf:type machine-info-bc)
    (modify ?sf (count 1) (time 0 0))
  )

  ; Set lights
  (delayed-do-for-all-facts ((?machine machine)) TRUE
    (modify ?machine (desired-lights GREEN-ON))
  )

  ;(assert (attention-message (text "Entering Production Phase")))
)

(defrule prod-machine-down
  (declare (salience ?*PRIORITY_HIGHER*))
  (gamestate (phase PRODUCTION) (state RUNNING) (game-time ?gt))
  ?mf <- (machine (name ?name) (mtype ?mtype)
		  (state ?state&~DOWN) (proc-start ?proc-start)
		  (down-period $?dp&:(<= (nth$ 1 ?dp) ?gt)&:(>= (nth$ 2 ?dp) ?gt)))
  =>
  (bind ?down-time (- (nth$ 2 ?dp) (nth$ 1 ?dp)))
  (printout t "Machine " ?name " down for " ?down-time " sec" crlf)
  (if (eq ?state PROCESSING)
   then
    (modify ?mf (state DOWN) (desired-lights RED-ON) (prev-state ?state)
	    (proc-start (+ ?proc-start ?down-time)))
   else
    (modify ?mf (state DOWN) (prev-state ?state) (desired-lights RED-ON))
  )
)

(defrule prod-machine-up
  (declare (salience ?*PRIORITY_HIGHER*))
  (gamestate (phase PRODUCTION) (state RUNNING) (game-time ?gt))
  ?mf <- (machine (name ?name) (state DOWN) (prev-state ?prev-state&~DOWN)
		  (mps-state-deferred ?mps-state)
		  (down-period $?dp&:(<= (nth$ 2 ?dp) ?gt)))
  =>
  (printout t "Machine " ?name " is up again" crlf)
  (if (eq ?mps-state NONE)
   then (modify ?mf (state ?prev-state) (proc-state DOWN))
   else (modify ?mf (state ?prev-state) (proc-state DOWN)
		(mps-state ?mps-state) (mps-state-deferred NONE))
  )
)

(defrule prod-mps-state-ready
	?m <- (machine (name ?n))
  ?mps-status <- (mps-status-feedback ?n READY ?ready)
	=>
	(retract ?mps-status)
	(modify ?m (mps-ready ?ready))
)

(defrule prod-mps-state-busy
	?m <- (machine (name ?n))
  ?mps-status <- (mps-status-feedback ?n BUSY ?busy)
	=>
	(retract ?mps-status)
	(modify ?m (mps-busy ?busy))
)

(defrule prod-machine-prepare
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?pf <- (protobuf-msg (type "llsf_msgs.PrepareMachine") (ptr ?p)
		       (rcvd-from ?from-host ?from-port) (client-type ?ct) (client-id ?cid))
  (network-peer (id ?cid) (group ?group))
  =>
  (retract ?pf)
  (bind ?mname (sym-cat (pb-field-value ?p "machine")))
  (bind ?team (sym-cat (pb-field-value ?p "team_color")))
  (if (and (eq ?ct PEER) (neq ?team ?group))
   then
    ; message received for a team over the wrong channel, deny
    (assert (attention-message (team ?group)
	      (text (str-cat "Invalid prepare for team " ?team " of team " ?group))))
   else
    (if (not (any-factp ((?m machine)) (and (eq ?m:name ?mname) (eq ?m:team ?team))))
     then
      (assert (attention-message (team ?team)
		(text (str-cat "Prepare received for invalid machine " ?mname))))
     else
      (printout t "Received prepare for " ?mname crlf)
      (do-for-fact ((?m machine)) (and (eq ?m:name ?mname) (eq ?m:team ?team))
        (if (eq ?m:state IDLE) then
	  (printout t ?mname " is IDLE, processing prepare" crlf)
	  (switch ?m:mtype
            (case BS then
	      (if (pb-has-field ?p "instruction_bs")
	       then
	        (bind ?prepmsg (pb-field-value ?p "instruction_bs"))
		(bind ?side (sym-cat (pb-field-value ?prepmsg "side")))
		(bind ?color (sym-cat (pb-field-value ?prepmsg "color")))
		(printout t "Prepared " ?mname " (side: " ?side ", color: " ?color ")" crlf)
	        (modify ?m (state PREPARED) (bs-side  ?side) (bs-color ?color) (wait-for-product-since ?gt))
               else
		(modify ?m (state BROKEN)(prev-state ?m:state)
			(broken-reason (str-cat "Prepare received for " ?mname " without data")))
	      )
            )
            (case DS then
	      (if (pb-has-field ?p "instruction_ds")
	       then
	        (bind ?prepmsg (pb-field-value ?p "instruction_ds"))
		(bind ?order-id (pb-field-value ?prepmsg "order_id"))
		(if (any-factp ((?order order)) (eq ?order:id ?order-id))
		 then
			(printout t "Prepared " ?mname " (order: " ?order-id ")" crlf)
			(modify ?m (state PREPARED) (ds-order ?order-id)
                           (wait-for-product-since ?gt))
		else
			(modify ?m (state BROKEN) (prev-state ?m:state)
			  (broken-reason (str-cat "Prepare received for " ?mname " with invalid order ID")))
		)
               else
		(modify ?m (state BROKEN) (prev-state ?m:state)
			(broken-reason (str-cat "Prepare received for " ?mname " without data")))
	      )
            )
            (case SS then
	      (if (pb-has-field ?p "instruction_ss")
	       then
	        (bind ?prepmsg (pb-field-value ?p "instruction_ss"))
	        (bind ?task (pb-field-value ?prepmsg "task"))
		(bind ?operation (sym-cat (pb-field-value ?task "operation")))
		(bind ?slot (pb-field-value ?task "shelf"))
                (bind ?slot-x (pb-field-value ?slot "x"))
                (bind ?slot-y (pb-field-value ?slot "y"))
                (bind ?slot-z (pb-field-value ?slot "z"))

                (if (eq ?operation RETRIEVE)
                 then
                  ; check if slot is filled
                  (if (any-factp ((?ss-slot machine-ss-filled)) (and (eq ?ss-slot:name ?mname)
                                                                     (and (eq (nth$ 1 ?ss-slot:slot) ?slot-x)
                                                                          (and (eq (nth$ 2 ?ss-slot:slot) ?slot-y)
                                                                               (eq (nth$ 3 ?ss-slot:slot) ?slot-z)
                                                                          )
                                                                     )
                                                                )
                      )
                   then
                    (printout t "Prepared " ?mname " (RETRIVE: (" ?slot-x ", " ?slot-y ", " ?slot-z ") )" crlf)
                    (modify ?m (state PREPARED) (ss-operation ?operation) (ss-slot ?slot-x ?slot-y ?slot-z) (wait-for-product-since ?gt))
                   else
		    (modify ?m (state BROKEN)(prev-state ?m:state) (broken-reason (str-cat "Prepare received for " ?mname " with RETRIVE (" ?slot-x ", " ?slot-y ", " ?slot-z ") but this is empty")))
                  )
                 else
                  (if (eq ?operation STORE)
                   then
		    (modify ?m (state BROKEN)(prev-state ?m:state) (broken-reason (str-cat "Prepare received for " ?mname " with STORE-operation")))
                   else
		    (modify ?m (state BROKEN)(prev-state ?m:state) (broken-reason (str-cat "Prepare received for " ?mname " with unknown operation")))
                  )
                )
               else
		(modify ?m (state BROKEN)(prev-state ?m:state)
			(broken-reason (str-cat "Prepare received for " ?mname " without data")))
	      )
            )
            (case RS then
	      (if (pb-has-field ?p "instruction_rs")
	       then
	        (bind ?prepmsg (pb-field-value ?p "instruction_rs"))
		(bind ?ring-color (sym-cat (pb-field-value ?prepmsg "ring_color")))
		(if (member$ ?ring-color ?m:rs-ring-colors)
		 then
		  (printout t "Prepared " ?mname " (ring color: " ?ring-color ")" crlf)
	          (modify ?m (state PREPARED) (rs-ring-color ?ring-color)
                             (wait-for-product-since ?gt))
                 else
		  (modify ?m (state BROKEN) (prev-state ?m:state)
			  (broken-reason (str-cat "Prepare received for " ?mname
						  " for invalid ring color (" ?ring-color ")")))
                )
               else
		(modify ?m (state BROKEN) (prev-state ?m:state)
			(broken-reason (str-cat "Prepare received for " ?mname " without data")))
              )
            )
            (case CS then
	      (if (pb-has-field ?p "instruction_cs")
	       then
	        (bind ?prepmsg (pb-field-value ?p "instruction_cs"))
		(bind ?cs-op (sym-cat (pb-field-value ?prepmsg "operation")))
		(switch ?cs-op

		  (case RETRIEVE_CAP then
		    (if (not ?m:cs-retrieved)
		     then
 		      (printout t "Prepared " ?mname " (" ?cs-op ")" crlf)
	              (modify ?m (state PREPARED) (cs-operation ?cs-op)
                                  (wait-for-product-since ?gt))
                     else
		      (modify ?m (state BROKEN) (prev-state ?m:state)
			      (cs-retrieved FALSE)
			      (broken-reason (str-cat "Prepare received for " ?mname ": "
						      "cannot retrieve while already holding")))
                    )
                  )
		  (case MOUNT_CAP then
		    (if ?m:cs-retrieved
		     then
 		      (printout t "Prepared " ?mname " (" ?cs-op ")" crlf)
	              (modify ?m (state PREPARED) (cs-operation ?cs-op)
                                  (wait-for-product-since ?gt))
                     else
		      (modify ?m (state BROKEN) (prev-state ?m:state)
			      (broken-reason (str-cat "Prepare received for " ?mname
						      ": cannot mount without cap")))
                    )
		  )
                )
               else
		(modify ?m (state BROKEN) (prev-state ?m:state)
			(broken-reason (str-cat "Prepare received for " ?mname " without data")))
	      )
            )
          )
        else
          (if (eq ?m:state READY-AT-OUTPUT) then
            (modify ?m (state BROKEN) (prev-state ?m:state))
          )
        )
      )
    )
  )
)

(defrule prod-machine-reset-by-team
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?pf <- (protobuf-msg (type "llsf_msgs.ResetMachine") (ptr ?p)
		     (rcvd-from ?from-host ?from-port) (client-type ?ct) (client-id ?cid))
  (network-peer (id ?cid) (group ?group))
  =>
  (retract ?pf)
  (bind ?mname (sym-cat (pb-field-value ?p "machine")))
  (bind ?team (sym-cat (pb-field-value ?p "team_color")))
  (if (and (eq ?ct PEER) (neq ?team ?group))
   then
    ; message received for a team over the wrong channel, deny
    (assert (attention-message (team ?group)
	      (text (str-cat "Invalid reset for team " ?team " of team " ?group))))
   else
    (if (not (any-factp ((?m machine)) (and (eq ?m:name ?mname) (eq ?m:team ?team))))
     then
      (assert (attention-message (team ?team)
		(text (str-cat "Reset received for invalid machine " ?mname))))
     else
      (printout t "Received reset for " ?mname crlf)
      (do-for-fact ((?m machine)) (and (eq ?m:name ?mname) (eq ?m:team ?team))
	(modify ?m (state BROKEN) (prev-state ?m:state)
                   (broken-reason (str-cat "Machine " ?mname " resetted by the team " ?team)))
      )
    )
  )
)

; **** Machine state processing

(defrule prod-proc-state-idle
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (state IDLE) (proc-state ~IDLE))
  =>
  (printout t "Machine " ?n " switching to IDLE state" crlf)
  (modify ?m (proc-state IDLE) (desired-lights GREEN-ON) (task nil))
  (mps-reset (str-cat ?n))
)

(defrule prod-proc-state-prepared-stop-blinking
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (state PREPARED|PROCESSING)
		 (actual-lights GREEN-BLINK) (desired-lights GREEN-BLINK)
		 (prep-blink-start ?bs&:(timeout-sec ?gt ?bs ?*PREPARED-BLINK-TIME*)))
  =>
  (modify ?m (desired-lights GREEN-ON))
)

(defrule production-bs-dispense
  "BS must be instructed to dispense base for processing"
  (declare (salience ?*PRIORITY_HIGH*))
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (mtype BS) (state PREPARED) (bs-color ?color) (task nil))
  =>
  (printout t "Machine " ?n " dispensing " ?color " base" crlf)
  (modify ?m (state PROCESSING) (desired-lights GREEN-ON YELLOW-ON)
	           (task DISPENSE) (mps-busy TRUE))
  (mps-bs-dispense (str-cat ?n) (str-cat ?color))
)

(defrule prod-bs-move-conveyor
	"The BS has dispensed a base. We now need to move the conveyor"
  (declare (salience ?*PRIORITY_HIGH*))
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
	?m <- (machine (name ?n) (mtype BS) (state PROCESSING) (task DISPENSE) (mps-busy FALSE) (bs-side ?side))
	=>
	(printout t "Machine " ?n " moving base to " ?side crlf)
	(modify ?m (task MOVE-OUT) (state PROCESSED) (mps-busy TRUE))
	(if (eq ?side INPUT)
	 then
		(mps-move-conveyor (str-cat ?n) "INPUT" "BACKWARD")
	 else
		(mps-move-conveyor (str-cat ?n) "OUTPUT" "FORWARD")
	)
)

(defrule production-bs-idle
	"The base has been picked up"
	?m <- (machine (name ?n) (mtype BS|RS) (state READY-AT-OUTPUT) (task MOVE-OUT) (mps-ready FALSE))
	=>
	(modify ?m (state IDLE))
	(mps-reset (str-cat ?n))
)

(defrule production-rs-insufficient-bases
  "Must check sufficient number of bases for RS"
  (declare (salience ?*PRIORITY_HIGHER*))
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (mtype RS) (state PREPARED)
		 (rs-ring-color ?ring-color) (bases-added ?ba) (bases-used ?bu))
  (ring-spec (color ?ring-color)
	     (req-bases ?req-bases&:(> ?req-bases (- ?ba ?bu))))
  =>
  (modify ?m (state BROKEN)
	  (broken-reason (str-cat ?n ": insufficient bases ("
				  (- ?ba ?bu) " < " ?req-bases ")")))
)

(defrule production-rs-start
  "Instruct RS to mount ring"
  (declare (salience ?*PRIORITY_HIGHER*))
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (mtype RS) (state PREPARED) (task nil)
		 (rs-ring-color ?ring-color) (rs-ring-colors $?ring-colors)
                 (bases-added ?ba) (bases-used ?bu))
  (ring-spec (color ?ring-color) (req-bases ?req-bases&:(>= (- ?ba ?bu) ?req-bases)))
  =>
  (printout t "Machine " ?n " of type RS switching to PREPARED state" crlf)
  (modify ?m (desired-lights GREEN-BLINK) (task MOVE-MID) (mps-busy TRUE)
             (prep-blink-start ?gt))
  (mps-move-conveyor (str-cat ?n) "MIDDLE" "FORWARD")
)

(defrule production-rs-mount-ring
	"Workpiece is in the middle, mount a ring"
  (declare (salience ?*PRIORITY_HIGHER*))
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
	?m <- (machine (name ?n) (mtype RS) (state PREPARED) (task MOVE-MID) (mps-busy FALSE)
	               (rs-ring-color ?ring-color) (rs-ring-colors $?ring-colors) (bases-used ?bu))
  (ring-spec (color ?ring-color) (req-bases ?req-bases))
	=>
	(printout t "Machine " ?n ": mount ring" crlf)
	(modify ?m (state PROCESSING) (task MOUNT-RING) (mps-busy TRUE) (bases-used (+ ?bu ?req-bases)) (desired-lights GREEN-ON YELLOW-ON))
  (mps-rs-mount-ring (str-cat ?n) (member$ ?ring-color ?ring-colors))
)

(defrule production-rs-move-to-output
	"Ring is mounted, move to output"
	(declare (salience ?*PRIORITY_HIGHER*))
	(gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
	?m <- (machine (name ?n) (mtype RS) (state PROCESSING) (task MOUNT-RING) (mps-busy FALSE))
	=>
	(printout t "Machine " ?n ": move to output" crlf)
	(modify ?m (state PROCESSED) (task MOVE-OUT) (mps-busy TRUE))
	(mps-move-conveyor (str-cat ?n) "OUTPUT" "FORWARD")
)

(defrule production-bs-cs-rs-ready-at-output
	"Workpiece is in output, switch to READY-AT-OUTPUT"
	(declare (salience ?*PRIORITY_HIGHER*))
	(gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
	?m <- (machine (name ?n) (mtype BS|CS|RS) (state PROCESSED) (task MOVE-OUT)
	               (mps-busy FALSE) (mps-ready TRUE))
	=>
	(modify ?m (state READY-AT-OUTPUT) (task nil))
)

(defrule production-rs-ignore-slide-counter-in-non-production
	"We are not in production phase, ignore slide events on the RS"
	(gamestate (phase ~PRODUCTION))
	?fb <- (mps-status-feedback ?n SLIDE-COUNTER ?bases)
	?m <- (machine (name ?n))
	=>
	(modify ?m (mps-base-counter ?bases))
	(retract ?fb)
)

(defrule production-rs-new-base-on-slide
	"The counter for the RS slide has been updated"
	(declare (salience ?*PRIORITY_HIGHER*))
	(gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
	?m <- (machine (name ?n) (state ?state) (mtype RS) (team ?team)
	               (bases-used ?bases-used) (bases-added ?old-num-bases)
	               (mps-base-counter ?mps-counter))
	?fb <- (mps-status-feedback ?n SLIDE-COUNTER ?new-counter&:(> ?new-counter ?mps-counter))
	=>
	(retract ?fb)
	(if (neq ?state BROKEN)
	 then
		(bind ?num-bases (+ 1 ?old-num-bases))
		(printout t "Machine " ?n " base added (count: " ?num-bases ")" crlf)
		(if (<= (- ?num-bases ?bases-used) ?*LOADED-WITH-MAX*)
		 then
			(assert (points (game-time ?gt) (points ?*PRODUCTION-POINTS-ADDITIONAL-BASE*)
			                (team ?team) (phase PRODUCTION)
			                (reason (str-cat "Added additional base to " ?n))))
			(modify ?m (bases-added ?num-bases))
		 else
			(modify ?m (state BROKEN) (prev-state ?state)
			           (broken-reason (str-cat ?n ": too many additional bases loaded")))
		)
	)
)

(defrule production-cs-mount-without-retrieve
  "Process on CS"
  (declare (salience ?*PRIORITY_HIGHER*))
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (mtype CS) (state PREPARED)
		 (cs-operation MOUNT_CAP) (cs-retrieved FALSE))
  =>
  (modify ?m (state BROKEN) (proc-state PROCESSING)
	  (broken-reason (str-cat ?n ": tried to mount without retrieving")))
)

(defrule production-cs-cap-move-to-mid
  "Process on CS"
  (declare (salience ?*PRIORITY_HIGHER*))
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (mtype CS) (state PREPARED) (task nil)
	               (cs-operation ?cs-op))
  =>
  (printout t "Machine " ?n " prepared for " ?cs-op crlf)
  (modify ?m (desired-lights GREEN-BLINK)
						 (task MOVE-MID) (prep-blink-start ?gt) (mps-busy TRUE))
	(mps-move-conveyor (str-cat ?n) "MIDDLE" "FORWARD")
)

(defrule production-cs-cap-main-op
	?m <- (machine (name ?n) (mtype CS) (state PREPARED) (task MOVE-MID) (mps-busy FALSE)
	               (cs-operation ?cs-op))
	=>
	(modify ?m (state PROCESSING) (desired-lights GREEN-ON YELLOW-ON) (task ?cs-op) (mps-busy TRUE))
	(if (eq ?cs-op RETRIEVE_CAP)
	 then
		(mps-cs-retrieve-cap (str-cat ?n))
		(printout t "Machine " ?n " retrieving a cap" crlf)
	 else
		(mps-cs-mount-cap (str-cat ?n))
		(printout t "Machine " ?n " mounting a cap" crlf)
	)
)

(defrule production-cs-move-to-output
	?m <- (machine (name ?n) (mtype CS) (state PROCESSING) (task ?cs-op&RETRIEVE_CAP|MOUNT_CAP)
	               (mps-busy FALSE))
	=>
	(printout t "Machine " ?n ": move to output" crlf)
	(mps-move-conveyor (str-cat ?n) "OUTPUT" "FORWARD")
	(modify ?m (state PROCESSED) (task MOVE-OUT) (mps-busy TRUE)
	           (cs-retrieved (eq ?cs-op RETRIEVE_CAP)))
)

(defrule production-mps-product-retrieved
	?m <- (machine (name ?n) (state READY-AT-OUTPUT) (mps-ready FALSE))
	=>
	(modify ?m (state IDLE) (desired-lights GREEN-ON))
	(mps-reset (str-cat ?n))
)

(defrule production-ds-start-processing
	"DS is prepared, start processing"
  (declare (salience ?*PRIORITY_HIGHER*))
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
	?m <- (machine (name ?n) (mtype DS) (state PREPARED) (task nil) (ds-order ?order))
  (order (id ?order) (delivery-gate ?gate))
	=>
  (printout t "Machine " ?n " processing to gate " ?gate " for order " ?order crlf)
	(modify ?m (state PROCESSING) (task DELIVER) (mps-busy TRUE)
	           (desired-lights GREEN-ON YELLOW-ON))
  (mps-ds-process (str-cat ?n) ?gate)
)

(defrule production-ds-order-delivered
	(declare (salience ?*PRIORITY_HIGH*))
	(gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
	?m <- (machine (name ?n) (mtype DS) (state PROCESSING) (task DELIVER) (mps-busy FALSE)
	               (ds-order ?order) (team ?team))
  =>
	(modify ?m (state PROCESSED) (task nil))
	(assert (product-delivered (order ?order) (team ?team) (game-time ?gt)
	                           (confirmed FALSE)))
	(assert (attention-message (team ?team)
	                           (text (str-cat "Please confirm delivery for order " ?order))))
)

(defrule production-ds-processed
  (declare (salience ?*PRIORITY_HIGH*))
	?m <- (machine (name ?n) (mtype DS) (state PROCESSED))
	=>
  (printout t "Machine " ?n " finished processing" crlf)
  (modify ?m (state IDLE) (desired-lights GREEN-ON))
	(mps-reset (str-cat ?n))
)

(defrule production-lights-ready-at-output
  (gamestate (state RUNNING) (phase PRODUCTION))
  ?m <- (machine (state READY-AT-OUTPUT) (desired-lights $?d&:(neq ?d (create$ YELLOW-ON))))
  =>
  (modify ?m (desired-lights YELLOW-ON))
)

(defrule prod-proc-state-broken
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (state BROKEN) (proc-state ~BROKEN)
		 (team ?team) (broken-reason ?reason))
  =>
  (printout t "Machine " ?n " broken: " ?reason crlf)
  (assert (attention-message (team ?team) (text ?reason)))
  (modify ?m (proc-state BROKEN) (broken-since ?gt)
	  (desired-lights RED-BLINK YELLOW-BLINK))
  (mps-reset (str-cat ?n))
)

(defrule prod-proc-state-broken-recover
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (state BROKEN) (bases-added ?ba)
		 (broken-since ?bs&:(timeout-sec ?gt ?bs ?*BROKEN-DOWN-TIME*)))
  =>
  (printout t "Machine " ?n " recovered" crlf)
  (modify ?m (state IDLE) (prev-state BROKEN) (bases-used ?ba) (cs-retrieved FALSE))
)


; **** MPS state changes

; **** Mapping MPS to machine state reactions
(defrule prod-machine-reset
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))

  ?m <- (machine (name ?n) (state ?state&~IDLE) (mps-state RESET))
  =>
  (modify ?m (state IDLE) (prev-state IDLE) (proc-state IDLE) (desired-lights GREEN-ON)
	  (mps-state IDLE) (mps-state-deferred NONE) (broken-reason "")
    (ds-gate 0) (ds-last-gate 0) (cs-retrieved FALSE))
)

(defrule prod-mps-state-available
	?m <- (machine (name ?n))
	?fb <- (mps-feedback ?n ? AVAILABLE)
	=>
	(modify ?m (mps-state AVAILABLE))
	(retract ?fb)
)

(defrule prod-machine-input
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (state PREPARED) (mps-state AVAILABLE))
  =>
  (modify ?m (state PROCESSING) (proc-start ?gt) (mps-state AVAILABLE-HANDLED))
)

(defrule prod-prepared-but-no-input
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (mtype ?type&~BS) (state ?state
	               &:(or (and (member$ ?type (create$ DS BS)) (eq ?state PROCESSING)) (eq ?state PREPARED)))
        (wait-for-product-since ?ws&:(timeout-sec ?gt ?ws ?*PREPARE-WAIT-TILL-RESET*)))
  =>
  (modify ?m (state BROKEN) (prev-state PROCESSING)
             (broken-reason (str-cat "MPS " ?n " prepared, but no product feed in time")))
)

(defrule prod-processing-timeout
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (state PROCESSING|PROCESSED)
        (wait-for-product-since ?ws
	        &:(timeout-sec ?gt ?ws (+ ?*PREPARE-WAIT-TILL-RESET* ?*PROCESSING-WAIT-TILL-RESET*))))
	=>
	(printout error "Machine " ?n " timed out while processing" crlf)
	(modify ?m (state IDLE) (task nil))
	(mps-reset (str-cat ?n))
)

(defrule prod-machine-proc-done
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (state PROCESSING) (mps-state PROCESSED)
		 (proc-time ?pt) (proc-start ?pstart&:(timeout-sec ?gt ?pstart ?pt)))
  =>
  (modify ?m (state PROCESSED))
)

(defrule prod-machine-ready-at-output
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?m <- (machine (name ?n) (state PROCESSING|PROCESSED) (mps-state DELIVERED)
		 (proc-time ?pt) (proc-start ?pstart&:(timeout-sec ?gt ?pstart ?pt)))
  =>
  (modify ?m (state READY-AT-OUTPUT))
)

(defrule prod-pb-recv-SetMachineState
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?pf <- (protobuf-msg (type "llsf_msgs.SetMachineState") (ptr ?p) (rcvd-via STREAM)
		       (rcvd-from ?from-host ?from-port) (client-id ?cid))
  =>
  (bind ?mname (sym-cat (pb-field-value ?p "machine_name")))
  (bind ?state (sym-cat (pb-field-value ?p "state")))
  (printout t "Received state " ?state " for machine " ?mname crlf)
  (do-for-fact ((?m machine)) (eq ?m:name ?mname)
    (assert (machine-mps-state (name ?mname) (state ?state) (num-bases ?m:bases-added)))
  )
)

(defrule prod-pb-recv-MachineAddBase
  (gamestate (state RUNNING) (phase PRODUCTION) (game-time ?gt))
  ?pf <- (protobuf-msg (type "llsf_msgs.MachineAddBase") (ptr ?p) (rcvd-via STREAM)
		       (rcvd-from ?from-host ?from-port) (client-id ?cid))
  =>
  (bind ?mname (sym-cat (pb-field-value ?p "machine_name")))
  (printout t "Add base to machine " ?mname crlf)
  (do-for-fact ((?m machine)) (eq ?m:name ?mname)
    (assert (machine-mps-state (name ?mname) (state ?m:mps-state)
			       (num-bases (+ ?m:bases-added 1))))
  )
)
