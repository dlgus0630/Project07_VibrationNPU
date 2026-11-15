#ifndef MOTOR_COMMANDS_H
#define MOTOR_COMMANDS_H

void motor_print_safety(void);
void motor_run_open_loop_steps(void);
void motor_set_gains(int use_candidate);
void motor_set_anti_windup(int enabled);
void motor_preset_quad_position(void);

#endif
