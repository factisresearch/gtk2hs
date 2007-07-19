-- GIMP Toolkit (GTK) Binding for Haskell: binding to gstreamer   -*-haskell-*-
--
--  Author : Peter Gavin
--  Created: 1-Apr-2007
--
--  Version $Revision$ from $Date$
--
--  Copyright (c) 2007 Peter Gavin
--
--  This library is free software; you can redistribute it and/or
--  modify it under the terms of the GNU Library General Public
--  License as published by the Free Software Foundation; either
--  version 2 of the License, or (at your option) any later version.
--
--  This library is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
--  Library General Public License for more details.
--
module Media.Streaming.GStreamer.PadTemplate (
  
  PadTemplate,
  PadTemplateClass,
  castToPadTemplate,
  toPadTemplate,
  fromPadTemplate,
  PadFlags(..),
  PadPresence(..),
  
  padTemplateNew,
  padTemplateGetCaps,
  padTemplateGetNameTemplate,
  padTemplateGetDirection,
  padTemplateGetPresence
  
  ) where

import Control.Monad (liftM)
{#import Media.Streaming.GStreamer.Types#}
import System.Glib.FFI
import System.Glib.UTFString

{# context lib = "gstreamer" prefix = "gst" #}

padTemplateNew :: String
               -> PadDirection
               -> PadPresence
               -> Caps
               -> IO PadTemplate
padTemplateNew nameTemplate direction presence caps =
    withUTFString nameTemplate $ \cNameTemplate ->
    giveCaps caps $ \caps' ->
        {# call pad_template_new #} cNameTemplate
                                    (fromIntegral $ fromEnum direction)
                                    (fromIntegral $ fromEnum presence)
                                    caps' >>=
            newPadTemplate

padTemplateGetCaps :: PadTemplateClass padTemplate
                   => padTemplate
                   -> IO Caps
padTemplateGetCaps padTemplate =
    {# call pad_template_get_caps #} (toPadTemplate padTemplate) >>=
        newCaps_

padTemplateGetNameTemplate :: PadTemplateClass padTemplate
                           => padTemplate
                           -> IO String
padTemplateGetNameTemplate padTemplate =
    withPadTemplate (toPadTemplate padTemplate) {# get PadTemplate->name_template #} >>=
        peekUTFString

padTemplateGetDirection :: PadTemplateClass padTemplate
                        => padTemplate
                        -> IO PadDirection
padTemplateGetDirection padTemplate =
    liftM (toEnum . fromIntegral) $
        withPadTemplate (toPadTemplate padTemplate) {# get PadTemplate->direction #}

padTemplateGetPresence :: PadTemplateClass padTemplate
                       => padTemplate
                       -> IO PadPresence
padTemplateGetPresence padTemplate =
    liftM (toEnum . fromIntegral) $
        withPadTemplate (toPadTemplate padTemplate) {# get PadTemplate->presence #}