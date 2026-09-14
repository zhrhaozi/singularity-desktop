#ifndef SINGULARITY_PHYSICS_BRIDGE_H
#define SINGULARITY_PHYSICS_BRIDGE_H
typedef struct SGOrbitWorld SGOrbitWorld;
typedef struct { double x, y, vx, vy; } SGOrbitState;
SGOrbitWorld *sg_orbit_create(int count);
void sg_orbit_destroy(SGOrbitWorld *world);
void sg_orbit_set_state(SGOrbitWorld *world, int index, SGOrbitState state);
SGOrbitState sg_orbit_get_state(SGOrbitWorld *world, int index);
void sg_orbit_configure(SGOrbitWorld *world, double gravity, double softening,
                        double repelRange, double repelStrength, double containment);
void sg_orbit_step(SGOrbitWorld *world, double dt);
double sg_orbit_impact(SGOrbitWorld *world, int index);
unsigned long long sg_orbit_collisions(SGOrbitWorld *world);
const char *sg_orbit_engine(void);
#endif
