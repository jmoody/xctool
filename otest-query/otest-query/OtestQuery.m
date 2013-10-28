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


#import "OtestQuery.h"

#import <dlfcn.h>
#import <objc/objc-runtime.h>
#import <objc/runtime.h>
#import <stdio.h>

#import "DuplicateTestNameFix.h"
#import "ParseTestName.h"
#import "TestingFramework.h"

@implementation OtestQuery

/**
 Crawls through the test suite hierarchy and returns a list of all test case
 names in the format of ...

   @[@"-[SomeClass someMethod]",
     @"-[SomeClass otherMethod]"]
 */
+ (NSArray *)testNamesFromSuite:(id)testSuite
{
  NSMutableArray *names = [NSMutableArray array];

  for (id test in TestsFromSuite(testSuite)) {
    NSString *name = [test performSelector:@selector(name)];
    NSAssert(name != nil, @"Can't get name for test: %@", test);
    [names addObject:name];
  }

  return names;
}

+ (void)queryTestBundlePath:(NSString *)testBundlePath
{
  NSBundle *bundle = [NSBundle bundleWithPath:testBundlePath];
  if (!bundle) {
    fprintf(stderr, "Bundle '%s' does not identify an accessible bundle directory.\n",
            [testBundlePath UTF8String]);
    exit(kBundleOpenError);
  }

  NSDictionary *framework = FrameworkInfoForTestBundleAtPath(testBundlePath);
  if (!framework) {
    const char *bundleExtension = [[testBundlePath pathExtension] UTF8String];
    fprintf(stderr, "The bundle extension '%s' is not supported.\n", bundleExtension);
    exit(kUnsupportedFramework);
  }

  if (![bundle executablePath]) {
    fprintf(stderr, "The bundle at %s does not contain an executable.\n", [testBundlePath UTF8String]);
    exit(kMissingExecutable);
  }

  // We use dlopen() instead of -[NSBundle loadAndReturnError] because, if
  // something goes wrong, dlerror() gives us a much more helpful error message.
  if (dlopen([[bundle executablePath] UTF8String], RTLD_NOW) == NULL) {
    fprintf(stderr, "%s\n", dlerror());
    exit(kDLOpenError);
  }

  [[NSBundle allFrameworks] makeObjectsPerformSelector:@selector(principalClass)];

  ApplyDuplicateTestNameFix([framework objectForKey:kTestingFrameworkTestProbeClassName],
                            [framework objectForKey:kTestingFrameworkTestCaseClassName]);

  Class testProbeClass = NSClassFromString([framework objectForKey:kTestingFrameworkTestProbeClassName]);
  NSCAssert(testProbeClass, @"Should have *TestProbe class");

  // By setting `-(XC|Sen)Test All`, we'll make `-[(XC|Sen)TestProbe specifiedTestSuite]`
  // return all tests.
  [[NSUserDefaults standardUserDefaults] setObject:@"All"
                                            forKey:[framework objectForKey:kTestingFrameworkFilterTestArgsKey]];
  id specifiedTestSuite = [testProbeClass performSelector:@selector(specifiedTestSuite)];
  NSCAssert(specifiedTestSuite, @"Should have gotten a test suite from specifiedTestSuite");


  NSArray *fullTestNames = [self testNamesFromSuite:specifiedTestSuite];
  NSMutableArray *testNames = [NSMutableArray array];

  for (NSString *fullTestName in fullTestNames) {
    NSString *className = nil;
    NSString *methodName = nil;
    ParseClassAndMethodFromTestName(&className, &methodName, fullTestName);

    [testNames addObject:[NSString stringWithFormat:@"%@/%@", className, methodName]];
  }
  
  [testNames sortUsingSelector:@selector(compare:)];

  NSData *json = [NSJSONSerialization dataWithJSONObject:testNames options:0 error:nil];
  [(NSFileHandle *)[NSFileHandle fileHandleWithStandardOutput] writeData:json];
  exit(kSuccess);
}

@end
