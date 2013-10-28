//
// Copyright 2013 Facebook
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ParseTestName.h"
#import "Swizzle.h"

NSArray *TestsFromSuite(id testSuite)
{
  NSMutableArray *tests = [NSMutableArray array];
  NSMutableArray *queue = [NSMutableArray array];
  [queue addObject:testSuite];

  while ([queue count] > 0) {
    id test = [queue objectAtIndex:0];
    [queue removeObjectAtIndex:0];

    if ([test isKindOfClass:[testSuite class]]) {
      // Both SenTestSuite and XCTestSuite keep a list of tests in an ivar
      // called 'tests'.
      id testsInSuite = [test valueForKey:@"tests"];
      NSCAssert(testsInSuite != nil, @"Can't get tests for suite: %@", testSuite);
      [queue addObjectsFromArray:testsInSuite];
    } else {
      [tests addObject:test];
    }
  }

  return tests;
}

/**
 Returns a dictionary that looks like...
 
 @{
   [SenTestCase class] : @[
                           [SomeTestCase class],
                           [SomeOtherTestCase class],
                          ],
   ...
   ... every other class ...
   ...
  };
 
 The keys are Class objects, and the values are arrays of Class objects that
 inherit from the class specified in the key.
 
 */
static NSDictionary *DictionaryOfClassesToSubclasses()
{
  __block BOOL (^classIsNSProxy)(Class) = ^(Class cls) {
    if (cls == NULL) {
      return NO;
    } else if (strcmp(class_getName(cls), "NSProxy") == 0) {
      return YES;
    } else {
      return classIsNSProxy(class_getSuperclass(cls));
    }
  };

  NSMutableDictionary *results = [NSMutableDictionary dictionary];

  int classesCount = objc_getClassList(NULL, 0);
  Class *classes = (Class *)malloc(sizeof(Class) * classesCount);
  NSCAssert(classes != NULL, @"malloc failed.");
  objc_getClassList(classes, classesCount);

  for (int i = 0; i < classesCount; i++) {
    Class class = classes[i];

    // We have to skip over NSProxy.  On 10.8, by some quirk, NSProxy cannot be
    // a key in a dictionary.  Even calling `[NSProxy class]` will trigger an
    // exception.
    if (classIsNSProxy(class)) {
      continue;
    }
    
    Class superClass = class_getSuperclass(class);

    if (superClass != NULL) {
      if ([results objectForKey:superClass] == nil) {
        [results setObject:[NSMutableArray array] forKey:(id <NSCopying>)superClass];
      }

      [[results objectForKey:superClass] addObject:class];
    }
  }

  free(classes);
  return results;
}

/**
 Returns YES when `cls` responds to selector `methodSel`.
 
 Unlike `class_getInstanceMethod`, this function does not look at the class's
 superclasses.  It only returns YES if `cls` itself implements the method.
 */
static BOOL ClassImplementsMethod(Class cls, SEL methodSel)
{
  unsigned int count = 0;
  Method *methods = class_copyMethodList(cls, &count);
  BOOL found = NO;

  for (int i = 0; i < count; i++) {
    if (sel_isEqual(method_getName(methods[i]), methodSel)) {
      found = YES;
      break;
    }
  }

  free(methods);
  return found;
}

static NSArray *TestCaseSubclassesThatImplementNameOrDescription(NSString *testCaseClassName)
{
  NSDictionary *classesToSubclasses = DictionaryOfClassesToSubclasses();
  NSMutableArray *q = [NSMutableArray arrayWithObject:NSClassFromString(testCaseClassName)];
  NSMutableArray *results = [NSMutableArray array];

  while ([q count] > 0) {
    Class cls = [q objectAtIndex:0];
    [q removeObjectAtIndex:0];

    if (ClassImplementsMethod(cls, @selector(name)) ||
        ClassImplementsMethod(cls, @selector(description))) {
      [results addObject:cls];
    }

    NSArray *subclasses = [classesToSubclasses objectForKey:cls];
    if (subclasses) {
      [q addObjectsFromArray:subclasses];
    }
  }

  return results;
}

// Key used by objc_setAssociatedObject
static int TestNameKey;

static NSString *TestCase_nameOrDescription(id self, SEL cmd)
{
  id name = objc_getAssociatedObject(self, &TestNameKey);

  if (name) {
    // The name has been overridden.
    return name;
  } else {
    // Walk this class's hierarchy until we find the first version of this selector.
    Class cls = [self class];
    for (;;) {
      NSString *selName = [NSString stringWithFormat:@"__%s_%s",
                           class_getName(cls),
                           sel_getName(cmd)];
      SEL sel = sel_registerName([selName UTF8String]);

      if ([self respondsToSelector:sel]) {
        return objc_msgSend(self, sel);
      } else {
        cls = class_getSuperclass(cls);
        NSCAssert(cls != NULL,
                  @"Walked the whole class hierarchy and didn't find the selector.");
      }
    }
  }
}

static void SwizzleAllTestCasesThatImplementNameOrDescription(NSString *testCaseClassNames)
{
  for (Class cls in TestCaseSubclassesThatImplementNameOrDescription(testCaseClassNames)) {
    // XCTest uses 'name' to display the name of the test.
    XTSwizzleSelectorForFunction(cls, @selector(name), (IMP)TestCase_nameOrDescription);
    // SenTestingKit uses 'description'
    XTSwizzleSelectorForFunction(cls, @selector(description), (IMP)TestCase_nameOrDescription);
  }
}

static NSString *TestNameWithCount(NSString *name, NSUInteger count) {
  NSString *className = nil;
  NSString *methodName = nil;
  ParseClassAndMethodFromTestName(&className, &methodName, name);

  return [NSString stringWithFormat:@"-[%@ %@_%ld]",
          className,
          methodName,
          (unsigned long)count];
}

static id TestProbe_specifiedTestSuite(Class cls, SEL cmd)
{
  id testSuite = objc_msgSend(cls,
                              sel_registerName([[NSString stringWithFormat:@"__%s_specifiedTestSuite",
                                                 class_getName(cls)] UTF8String]));

  NSCountedSet *seenCounts = [NSCountedSet set];

  for (id test in TestsFromSuite(testSuite)) {
    NSString *name = [test performSelector:@selector(name)];
    [seenCounts addObject:name];

    NSUInteger seenCount = [seenCounts countForObject:name];

    if (seenCount > 1) {
      // It's a duplicate - we need to override the name.
      objc_setAssociatedObject(test,
                               &TestNameKey,
                               TestNameWithCount(name, seenCount),
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }

  return testSuite;
}

void ApplyDuplicateTestNameFix(NSString *testProbeClassName,
                               NSString *testCaseClassName)
{
  // Hooks into `-[(Sen|XC)TestCase name]` so we have an opportunity to run
  // alternative test names for specific test cases.
  SwizzleAllTestCasesThatImplementNameOrDescription(testCaseClassName);

  // Hooks into `[-(Sen|XC)TestProbe specifiedTestSuite]` so we have a chance
  // to 1) scan over the entire list of tests to be run, 2) rewrite any
  // duplicate names we find, and 3) return the modified list to the caller.
  XTSwizzleClassSelectorForFunction(NSClassFromString(testProbeClassName),
                                    @selector(specifiedTestSuite),
                                    (IMP)TestProbe_specifiedTestSuite);
}
