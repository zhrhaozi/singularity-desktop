#include "PhysicsBridge.h"
#include "chipmunk/chipmunk.h"
#include <stdlib.h>

struct SGOrbitWorld {
    cpSpace *space;
    cpBody *bodies[3];
    cpShape *shapes[3];
    int count;
    double gravity, softening, repelRange, repelStrength, containment;
    double impacts[3];
    unsigned long long collisions;
};

static void collision_solved(cpArbiter *arbiter, cpSpace *space, cpDataPointer data) {
    if (!cpArbiterIsFirstContact(arbiter)) return;
    SGOrbitWorld *world = data;
    double impulse = cpvlength(cpArbiterTotalImpulse(arbiter));
    if (impulse < 0.005) return;
    cpBody *a, *b;
    cpArbiterGetBodies(arbiter, &a, &b);
    world->collisions++;
    for (int i = 0; i < world->count; i++) {
        if (world->bodies[i] == a || world->bodies[i] == b)
            world->impacts[i] = fmin(1.0, 0.35 + impulse * 2.0);
    }
}

// Chipmunk updates all positions before invoking velocity callbacks. Evaluate
// position-dependent forces here, not before cpSpaceStep, to avoid explicit
// Euler energy growth in the containment field.
static void update_velocity(cpBody *body, cpVect unused, cpFloat damping, cpFloat dt) {
    SGOrbitWorld *world = cpBodyGetUserData(body);
    cpVect p = cpBodyGetPosition(body);
    cpVect acceleration = cpvmult(p, -world->containment);
    for (int i = 0; i < world->count; i++) {
        if (world->bodies[i] == body) continue;
        cpVect delta = cpvsub(cpBodyGetPosition(world->bodies[i]), p);
        double r2 = cpvlengthsq(delta), r = sqrt(r2);
        double softened = r2 + world->softening * world->softening;
        double strength = world->gravity / (softened * sqrt(softened));
        if (r < world->repelRange && r > 1e-9)
            strength -= world->repelStrength * (world->repelRange - r) / (world->repelRange * r);
        acceleration = cpvadd(acceleration, cpvmult(delta, strength));
    }
    cpBodyUpdateVelocity(body, acceleration, damping, dt);
}

SGOrbitWorld *sg_orbit_create(int count) {
    if (count < 2 || count > 3) return NULL;
    SGOrbitWorld *world = calloc(1, sizeof(*world));
    if (!world) return NULL;
    world->count = count;
    world->space = cpSpaceNew();
    cpSpaceSetGravity(world->space, cpvzero);
    cpSpaceSetDamping(world->space, 1.0);
    cpSpaceSetCollisionSlop(world->space, 0.0005);
    cpSpaceSetIterations(world->space, 10);
    cpCollisionHandler *handler = cpSpaceAddDefaultCollisionHandler(world->space);
    handler->postSolveFunc = collision_solved;
    handler->userData = world;
    for (int i = 0; i < count; i++) {
        world->bodies[i] = cpSpaceAddBody(world->space, cpBodyNew(1.0, INFINITY));
        cpBodySetUserData(world->bodies[i], world);
        cpBodySetVelocityUpdateFunc(world->bodies[i], update_velocity);
        world->shapes[i] = cpSpaceAddShape(world->space,
            cpCircleShapeNew(world->bodies[i], count == 3 ? 0.023 : 0.056, cpvzero));
        cpShapeSetElasticity(world->shapes[i], 0.85);
        cpShapeSetFriction(world->shapes[i], 0.0);
    }
    return world;
}

void sg_orbit_destroy(SGOrbitWorld *world) {
    if (!world) return;
    for (int i = 0; i < world->count; i++) {
        cpSpaceRemoveShape(world->space, world->shapes[i]);
        cpShapeFree(world->shapes[i]);
        cpSpaceRemoveBody(world->space, world->bodies[i]);
        cpBodyFree(world->bodies[i]);
    }
    cpSpaceFree(world->space);
    free(world);
}

void sg_orbit_set_state(SGOrbitWorld *world, int index, SGOrbitState state) {
    if (!world || index < 0 || index >= world->count) return;
    cpBodySetPosition(world->bodies[index], cpv(state.x, state.y));
    cpBodySetVelocity(world->bodies[index], cpv(state.vx, state.vy));
}

SGOrbitState sg_orbit_get_state(SGOrbitWorld *world, int index) {
    if (!world || index < 0 || index >= world->count) return (SGOrbitState){0};
    cpVect p = cpBodyGetPosition(world->bodies[index]);
    cpVect v = cpBodyGetVelocity(world->bodies[index]);
    return (SGOrbitState){p.x, p.y, v.x, v.y};
}

void sg_orbit_configure(SGOrbitWorld *world, double gravity, double softening,
                        double repelRange, double repelStrength, double containment) {
    if (!world) return;
    world->gravity = gravity;
    world->softening = softening;
    world->repelRange = repelRange;
    world->repelStrength = repelStrength;
    world->containment = containment;
}

void sg_orbit_step(SGOrbitWorld *world, double dt) {
    if (world && dt > 0 && dt <= 0.02) {
        for (int i = 0; i < world->count; i++) world->impacts[i] *= exp(-4.0 * dt);
        cpSpaceStep(world->space, dt);
    }
}

double sg_orbit_impact(SGOrbitWorld *world, int index) {
    return world && index >= 0 && index < world->count ? world->impacts[index] : 0.0;
}

unsigned long long sg_orbit_collisions(SGOrbitWorld *world) {
    return world ? world->collisions : 0;
}

const char *sg_orbit_engine(void) { return cpVersionString; }
