#pragma once
#import <Foundation/Foundation.h>
typedef struct {
 CFTypeRef (*createApp)(pid_t);
 int (*copy)(CFTypeRef,CFStringRef,CFTypeRef *);
 int (*setTimeout)(CFTypeRef,float);
 CFTypeID (*elementTypeID)(void);
 CFTypeID (*valueTypeID)(void);
 Boolean (*getValue)(CFTypeRef,int,void *);
} VPAxFunctions;
NSDictionary *vp_ax_walk(VPAxFunctions functions, CFTypeRef root, pid_t pid, int maxElements, int maxDepth, int timeoutMS);
NSDictionary *vp_ax_hierarchy(int pid, int maxElements, int maxDepth, int timeoutMS);
